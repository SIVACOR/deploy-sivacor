#!/bin/bash
# SIVACOR worker — OpenStack Customization Script (cloud-init user-data).
# Runs once as root on first boot. Log: /var/log/sivacor-provision.log
# Full rationale: autoscaling_plan.md P1.2. Post-boot steps: ~/NEXT_STEPS.md
#
# NO SECRETS HERE: user-data is readable on the instance via
# curl http://169.254.169.254/openstack/latest/user_data and visible in the
# OpenStack API. Credentials go in /etc/sivacor/worker.env after boot.
#
# Target: JS2 Ubuntu 24.04 (noble), m3.medium+ (needs the 60 GB root disk).
# Verified 2026-07-30 on sivacor-test-worker-01: 92s, docker.io 29.1.3 already
# present in the JS2 base image, docker GID 112, 52 GB free after both pulls.

set -euo pipefail
exec > >(tee -a /var/log/sivacor-provision.log) 2>&1
echo "=== provisioning started $(date -Is) ==="

# ---- config: review these before launching -------------------------------
# Convention: the tag tracks the branch name, so worker and manager are provably
# the same build. NOTHING BUILDS THIS AUTOMATICALLY -- .github/workflows/docker.yml
# only pushes `latest`, and only from `main`. Build and push this tag by hand after
# any change to girder-sivacor, or a fresh VM boots stale code. When `distributed`
# merges to main, this becomes `latest`.
WORKER_IMAGE="docker.io/xarthisius/girder-sivacor:distributed"
GIRDER_HOST="girder.test.sivacor.org"
# Manager's TENANT ip, not its floating ip: OpenStack does not hairpin floating
# ips, and this keeps multi-GB uploads off the NAT. TLS still verifies (the cert
# is bound to the hostname, not the address).
MANAGER_TENANT_IP="10.3.37.91"
# Cold-pulling analysis images mid-run dominates latency (D4). stata/dynare are
# large - add only if this worker runs them.
PREPULL_IMAGES=("rocker/r-ver:4.3.1")
# Empty -> sivacor.<hostname>, unique per VM with no coordination.
WORKER_QUEUE_OVERRIDE=""
DEPLOY_USER="ubuntu"; DEPLOY_UID=1000; DEPLOY_GID=1000

# ---- packages ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io redis-tools gnupg ca-certificates curl jq
systemctl enable --now docker

# ---- docker GID: differs per VM, so discover rather than hardcode ---------
usermod -aG docker "$DEPLOY_USER"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
echo "--- docker GID: ${DOCKER_GID} ---"

# ---- directories ---------------------------------------------------------
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 755  /home/"$DEPLOY_USER"/volumes
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 1777 /home/"$DEPLOY_USER"/volumes/tmp
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 755  /home/"$DEPLOY_USER"/volumes/licenses
# 700 or gpg refuses the homedir; container runs as uid 1000.
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 700  /home/"$DEPLOY_USER"/.gnupg
install -d -m 755 /etc/sivacor

# ---- pin Girder to the tenant address ------------------------------------
grep -q "[[:space:]]${GIRDER_HOST}\$" /etc/hosts || \
  printf '%s\t%s\n' "$MANAGER_TENANT_IP" "$GIRDER_HOST" >> /etc/hosts

# ---- worker identity -----------------------------------------------------
# A chain is pinned to this queue after its first step (later steps need the
# local workdir), so the name must be stable across restarts.
WORKER_QUEUE="${WORKER_QUEUE_OVERRIDE:-sivacor.$(hostname -s)}"
echo "--- queue: ${WORKER_QUEUE} ---"

# ---- env file: docker --env-file format ----------------------------------
# Bare KEY=VALUE. NO 'export', NO quotes (quotes become part of the value).
# deploy-sivacor/.env is the opposite - it is shell-sourced and needs 'export'.
cat > /etc/sivacor/worker.env <<EOF
# Generated $(date -Is). Format: docker --env-file (no export, no quotes).
# Fill the FILL_ME values, then:
#   sudo sivacor-worker-preflight && sudo systemctl enable --now sivacor-worker

# Must match the server byte for byte (server encrypts job secrets, worker
# decrypts). Copy from deploy-sivacor/.env on the manager.
MASTER_KEY_HEX=FILL_ME

# Same redis password as the manager, in all three.
GIRDER_WORKER_BROKER=redis://:FILL_ME@${MANAGER_TENANT_IP}:6379/
GIRDER_WORKER_BACKEND=redis://:FILL_ME@${MANAGER_TENANT_IP}:6379/
GIRDER_NOTIFICATION_REDIS_URL=redis://:FILL_ME@${MANAGER_TENANT_IP}:6379/

# Signing runs on the worker while D2 is open, so the KEY MATERIAL must be in
# /home/${DEPLOY_USER}/.gnupg here. But the fingerprint and passphrase the worker
# actually signs with come from the SERVER: run_submission.py:343,361 reads the
# sivacor.tro_gpg_fingerprint / _passphrase Girder settings and passes those to
# TRO(). These two variables are read by NOTHING in the plugin -- they exist only
# so preflight can check the key. They MUST equal the server's settings, or
# tro_utils raises KeyError(<server fingerprint>) mid-submission.
#   On the manager: curl -H "Girder-Token: \$T" -X PUT \
#     "https://${GIRDER_HOST}/api/v1/system/setting?key=sivacor.tro_gpg_fingerprint&value=<FPR>"
GIRDER_SIVACOR_TRO_GPG_FINGERPRINT=FILL_ME
GIRDER_SIVACOR_TRO_GPG_PASSPHRASE=FILL_ME

# Discovered at provision time.
GIRDER_API_URL=https://${GIRDER_HOST}/api/v1
SIVACOR_WORKER_QUEUE=${WORKER_QUEUE}
DOCKER_HOST_TMP_ROOT=/home/${DEPLOY_USER}/volumes
GOSU_USER=${DEPLOY_UID}:${DEPLOY_GID}:${DOCKER_GID}
HOSTDIR=/

# A path on THIS HOST, not in the container: lib.py:424 passes it as the
# bind-mount source for the analysis container. Only applied when set, so it is
# harmless before the license file exists.
STATA_LICENSE_HOSTPATH=/home/${DEPLOY_USER}/volumes/licenses/stata.lic.19

# Do NOT add GIRDER_MONGO_URI (worker must not reach Mongo - that is the point
# of P1) or GIRDER_API_KEY (no longer needed anywhere).
EOF
chmod 600 /etc/sivacor/worker.env
printf '%s\n' "$WORKER_IMAGE" > /etc/sivacor/image

# ---- images --------------------------------------------------------------
docker pull -q "$WORKER_IMAGE" || echo "!! worker image pull FAILED"
for img in "${PREPULL_IMAGES[@]}"; do
  docker pull -q "$img" || echo "!! pull ${img} failed (non-fatal)"
done
df -h / | tail -1

# ---- systemd unit: installed, NOT started (needs credentials) ------------
# --entrypoint is REQUIRED: the image's ENTRYPOINT is the girder server
# (tini -- gunicorn ... girder_sivacor.asgi:app). Appending a command only passes
# args to it, so gunicorn runs and celery never starts. docker-stack.yml gets
# away with the plain `entrypoint:` key because compose overrides; docker run
# does not.
#
# --group-add: the image bakes the girder user into docker GID 112, and nothing
# reads GOSU_USER (no gosu binary, no entrypoint script - it is dead WholeTale
# config). So socket access would silently depend on this host's docker GID
# happening to be 112. Adding the real GID makes it work on any host.
#
# --queues must not include 'local': that is Girder core's queue and belongs to
# the manager's co-located worker. -c 1 + prefetch 1 = one submission at a time,
# so queue depth stays a usable autoscaling signal.
cat > /etc/systemd/system/sivacor-worker.service <<EOF
[Unit]
Description=SIVACOR celery worker
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker rm -f sivacor-worker
ExecStart=/usr/bin/docker run --rm --name sivacor-worker \\
  --entrypoint /usr/bin/tini \\
  --env-file /etc/sivacor/worker.env \\
  --add-host ${GIRDER_HOST}:${MANAGER_TENANT_IP} \\
  --group-add ${DOCKER_GID} \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  -v /home/${DEPLOY_USER}/volumes/tmp:/tmp \\
  -v /home/${DEPLOY_USER}/.gnupg:/home/girder/.gnupg \\
  ${WORKER_IMAGE} \\
  -- celery --app=girder_worker.app worker \\
    --queues=sivacor,${WORKER_QUEUE} \\
    --concurrency=1 \\
    --prefetch-multiplier=1 \\
    --loglevel=INFO
ExecStop=/usr/bin/docker stop sivacor-worker

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ---- preflight -----------------------------------------------------------
cat > /usr/local/bin/sivacor-worker-preflight <<'PF'
#!/bin/bash
# Check everything before celery: a failure here is far easier to read.
set -uo pipefail
E=/etc/sivacor/worker.env; fail=0
ok(){ echo "  OK   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }; warn(){ echo "  WARN $1"; }

echo "1. placeholders"
# Only assignment lines - the file's own instructions mention FILL_ME.
if grep -E '^[A-Z_]+=' "$E" | grep -q FILL_ME; then
  bad "FILL_ME left in $E:"; grep -nE '^[A-Z_]+=.*FILL_ME' "$E" | sed 's/^/       /'
else ok "none left"; fi
set -a; . <(grep -E '^[A-Z_]+=' "$E"); set +a

echo "2. env-file format"
grep -qE '^export ' "$E" && bad "'export ' present: --env-file is not a shell, it becomes part of the name" || ok "no export"
grep -qE '^[A-Z_]+="' "$E" && warn "quoted value: quotes become part of the value" || ok "no quotes"

echo "3. redis broker"
RH=$(sed -E 's|.*@([^:]+):.*|\1|' <<<"$GIRDER_WORKER_BROKER")
RP=$(sed -E 's|redis://:([^@]*)@.*|\1|' <<<"$GIRDER_WORKER_BROKER")
[ "$(redis-cli -h "$RH" -a "$RP" --no-auth-warning ping 2>/dev/null)" = PONG ] \
  && ok "PONG from ${RH}:6379" \
  || bad "no PONG from ${RH}:6379 - check the security group (6379 from the project CIDR) and password"

echo "4. girder over https"
c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${GIRDER_API_URL}/system/version" 2>/dev/null)
[ "$c" = 200 ] && ok "200 from ${GIRDER_API_URL}" \
  || bad "got '${c}' - cert, DNS, or floating-ip hairpin"

echo "5. gpg signing key (fingerprint here must equal the SERVER setting)"
G="sudo -u ubuntu GNUPGHOME=/home/ubuntu/.gnupg gpg"
F="${GIRDER_SIVACOR_TRO_GPG_FINGERPRINT:-}"
if [ ${#F} -ne 40 ]; then bad "fingerprint is ${#F} chars, needs the full 40"
elif ! $G --list-keys "$F" >/dev/null 2>&1; then bad "no PUBLIC key for $F (tro_utils calls list_keys() without secret=True)"
elif ! $G --list-secret-keys "$F" >/dev/null 2>&1; then bad "public key but no SECRET key for $F"
elif $G --batch --pinentry-mode loopback --passphrase "$GIRDER_SIVACOR_TRO_GPG_PASSPHRASE" \
        --local-user "$F" --detach-sign --output /dev/null <<<x 2>/dev/null; then ok "signed a test payload"
else bad "key present but signing failed - wrong passphrase, or loopback pinentry refused"; fi

echo "6. docker socket reachable FROM THE IMAGE"
# Not a GOSU_USER comparison: nothing reads GOSU_USER. What matters is whether
# the container's user can actually open the socket.
[ -S /var/run/docker.sock ] && ok "socket present on host" || bad "no docker socket"
IMG=$(cat /etc/sivacor/image)
GID=$(getent group docker | cut -d: -f3)
if docker run --rm --group-add "$GID" -v /var/run/docker.sock:/var/run/docker.sock \
     --entrypoint python "$IMG" -c 'import docker;docker.from_env().ping()' >/dev/null 2>&1; then
  ok "container can talk to the daemon (docker GID $GID)"
else
  bad "container CANNOT reach the docker socket - no analysis container can be started"
fi

echo "7. must-not-be-set"
grep -qE '^GIRDER_MONGO_URI=' "$E" && bad "GIRDER_MONGO_URI set - worker must not reach Mongo" || ok "absent"

echo
[ "$fail" = 0 ] && echo "PASSED - sudo systemctl enable --now sivacor-worker" || echo "FAILED - fix the above first"
exit "$fail"
PF
chmod 755 /usr/local/bin/sivacor-worker-preflight

# ---- post-boot checklist -------------------------------------------------
cat > /home/"$DEPLOY_USER"/NEXT_STEPS.md <<EOF
# SIVACOR worker - manual steps

Provisioned $(date -Is). Log: /var/log/sivacor-provision.log
Details: autoscaling_plan.md P1.2

Done already: docker + redis-tools; ${DEPLOY_USER} in docker group; volumes/tmp,
volumes/licenses, .gnupg created with correct owner/mode; ${GIRDER_HOST} pinned
to ${MANAGER_TENANT_IP}; worker image pulled; docker GID ${DOCKER_GID} in
GOSU_USER; queue ${WORKER_QUEUE}; systemd unit installed but stopped.

## 1. Credentials -- sudo nano /etc/sivacor/worker.env
MASTER_KEY_HEX (from the manager's .env, must match exactly), the redis password
in all three redis:// URLs, and the GPG fingerprint/passphrase from step 2.
Format: no 'export', no quotes.

## 2. TRS signing key
Signing runs here while D2 is open, so the key material must be in
/home/${DEPLOY_USER}/.gnupg. Use a THROWAWAY key - a TRO signed with the
production key is indistinguishable from a real one.

IMPORTANT: the fingerprint and passphrase the worker signs with come from the
SERVER, not from worker.env (run_submission.py:343,361 reads the
sivacor.tro_gpg_fingerprint / _passphrase settings). The two must match, or you
get KeyError(<server fingerprint>) mid-submission. After generating below, set
the server side from the manager:

    T=\$(curl -s -X POST -u admin "https://${GIRDER_HOST}/api/v1/user/authentication" | jq -r .authToken.token)
    for kv in "sivacor.tro_gpg_fingerprint=\$FPR" "sivacor.tro_gpg_passphrase=\$PASS"; do
      curl -s -X PUT -H "Girder-Token: \$T" \
        "https://${GIRDER_HOST}/api/v1/system/setting?key=\${kv%%=*}&value=\${kv#*=}"
    done

and put the same values in the manager's .env
(GIRDER_SIVACOR_TRO_GPG_FINGERPRINT / _PASSPHRASE) so setup_girder.py does not
revert them on the next make dev.

    sudo -u ${DEPLOY_USER} GNUPGHOME=/home/${DEPLOY_USER}/.gnupg gpg --batch \\
      --pinentry-mode loopback --passphrase 'PASS' \\
      --quick-generate-key "SIVACOR TRS (test) <support@sivacor.org>" rsa4096 sign 2y
    sudo -u ${DEPLOY_USER} GNUPGHOME=/home/${DEPLOY_USER}/.gnupg gpg \\
      --list-keys --with-colons | awk -F: '/^fpr:/ {print \$10; exit}'

If importing instead, the PUBLIC half must be in the keyring too, then
chown -R ${DEPLOY_UID}:${DEPLOY_GID} /home/${DEPLOY_USER}/.gnupg
Back up openpgp-revocs.d/<FPR>.rev off-box.

## 3. Stata license (only if this worker runs Stata)
Copy to /home/${DEPLOY_USER}/volumes/licenses/stata.lic.19 - without it Stata
exits non-zero and the visible error looks unrelated.

## 4. Start
    sudo sivacor-worker-preflight
    sudo systemctl enable --now sivacor-worker
    journalctl -u sivacor-worker -f

## 5. On the manager
Set SIVACOR_MANAGER_QUEUES=local,sivacor.static-01 so it stops taking
submissions, then:
    celery -A girder_worker.app inspect active_queues
    # manager: local, sivacor.static-01   worker: sivacor, ${WORKER_QUEUE}

Then P1 exit criteria: submit a job, watch meta.heartbeat advance, confirm live
logs reach the UI and the result package uploads through Traefik, then
'docker kill sivacor-worker' mid-run and check the job flips to ERROR with the
failure email in 'docker service logs wt_girder'.
EOF
chown "$DEPLOY_UID":"$DEPLOY_GID" /home/"$DEPLOY_USER"/NEXT_STEPS.md
printf '\n*** SIVACOR worker: read ~/NEXT_STEPS.md, credentials still needed ***\n\n' > /etc/motd

echo "=== finished $(date -Is): queue=${WORKER_QUEUE} docker_gid=${DOCKER_GID} ==="
