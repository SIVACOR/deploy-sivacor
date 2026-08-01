#!/bin/bash
# SIVACOR worker — cloud-init user-data, passed by launch-worker.py.
# Runs once as root on first boot. Log: /var/log/sivacor-provision.log
# Full rationale: autoscaling_plan.md P1.2. Post-boot steps: ~/NEXT_STEPS.md
#
# SECRETS: MASTER_KEY_HEX and REDIS_PASSWORD may be supplied in the config block
# below, and under autoscaling they are. DELIBERATE -- do not "fix" it. Both are
# shared-fleet values and anyone who can read this user-data can boot a worker and
# read them off it anyway. The real cost is that user-data outlives the instance in
# Nova's DB, so treat both as permanently disclosed to anyone who ever gets project
# read access, and rotate on membership change. Reasoning: autoscaling_plan.md P2.2.
# Left empty -> worker.env gets FILL_ME and the unit stays stopped, as before.
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
# launch-worker.py replaces the marker line below with assignments. Everything in
# this block therefore uses ${VAR:-default}, so an injected value wins and a
# hand-pasted run still works. Keep the marker on its own line, spelled exactly.
#__SIVACOR_INJECT__

WORKER_IMAGE="${WORKER_IMAGE:-docker.io/xarthisius/girder-sivacor:distributed}"
GIRDER_HOST="${GIRDER_HOST:-girder.test.sivacor.org}"
# Manager's TENANT ip, not its floating ip: OpenStack does not hairpin floating
# ips, and this keeps multi-GB uploads off the NAT. TLS still verifies (the cert
# is bound to the hostname, not the address).
MANAGER_TENANT_IP="${MANAGER_TENANT_IP:-10.3.37.197}"
# Analysis images fetched before the worker starts. The CONTROLLER sets this to the
# images the submission's workflow names -- a certainty, not a guess, and pulled before
# the worker accepts the task rather than silently mid-run. Guessing wrong costs
# startup time and disk the payload needs (D6). Empty unless you know. See P2.1.
declare -p PREPULL_IMAGES >/dev/null 2>&1 || PREPULL_IMAGES=()
# Empty -> sivacor.<instance-uuid>, unique per VM with no coordination.
WORKER_QUEUE_OVERRIDE="${WORKER_QUEUE_OVERRIDE:-}"
# Serve one submission, then stop consuming the shared dispatch queue, so the
# controller's arithmetic stays `desired == depth` (routing.py, plan P3.2).
# Defaults on: every VM this script provisions is autoscaled. Set 0 for a
# hand-made long-lived debug worker. The manager's static worker is configured
# by docker-stack.yml, not this file, and must never set it.
EPHEMERAL_WORKER="${EPHEMERAL_WORKER:-1}"
# Self-shutdown supervisor (P3.3). Powers the VM off once it has finished its
# work, so the controller can reap it as SHUTOFF -- which is why the worker needs
# no OpenStack credentials of its own. Defaults to following EPHEMERAL_WORKER;
# set 0 to keep a debug VM alive while you poke at it.
SELF_SHUTDOWN="${SELF_SHUTDOWN:-$EPHEMERAL_WORKER}"
# How long celery must be idle AND container-free before powering off.
IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_SEC:-300}"
# Nothing powers off before this much uptime, so a VM booted for a still-queued
# submission gets time to be handed it. Provisioning alone is ~90 s.
BOOT_GRACE_SEC="${BOOT_GRACE_SEC:-600}"
DEPLOY_USER="ubuntu"; DEPLOY_UID=1000; DEPLOY_GID=1000

# ---- secrets: filled in by the controller; empty = provision manually --------
# See the SECRETS note in the header before changing how these are delivered.
# Both must match the manager byte for byte. When BOTH are set, this script
# writes a complete worker.env and starts the worker itself -- no manual step.
MASTER_KEY_HEX="${MASTER_KEY_HEX:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

# ---- packages ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# No gnupg: since tro-utils 0.4.6 the keyring is only touched when signing, and
# signing runs on the manager. A worker needs no key material and no gpg binary.
apt-get install -y -q docker.io redis-tools ca-certificates curl jq
systemctl enable --now docker

# ---- docker GID: differs per VM, so discover rather than hardcode ---------
usermod -aG docker "$DEPLOY_USER"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
echo "--- docker GID: ${DOCKER_GID} ---"

# ---- directories ---------------------------------------------------------
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 755  /home/"$DEPLOY_USER"/volumes
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 1777 /home/"$DEPLOY_USER"/volumes/tmp
install -d -o "$DEPLOY_UID" -g "$DEPLOY_GID" -m 755  /home/"$DEPLOY_USER"/volumes/licenses
install -d -m 755 /etc/sivacor

# ---- pin Girder to the tenant address ------------------------------------
grep -q "[[:space:]]${GIRDER_HOST}\$" /etc/hosts || \
  printf '%s\t%s\n' "$MANAGER_TENANT_IP" "$GIRDER_HOST" >> /etc/hosts

# ---- worker identity -----------------------------------------------------
# A chain is pinned to this queue after its first step (later steps need the
# local workdir), so the name must be stable for the life of the instance.
#
# Instance UUID beats hostname: unique by construction, no coordination. Hostnames
# derive from the instance *name*, and two instances sharing one would silently
# merge two submissions onto a single queue, each stealing steps that expect the
# other's workspace. Falls back to hostname if metadata is unreachable -- a worse
# queue name beats a VM that failed to provision.
if ! WORKER_UUID=$(curl -sf --max-time 5 \
      http://169.254.169.254/openstack/latest/meta_data.json | jq -re .uuid); then
  WORKER_UUID=""
  echo "!! metadata service unreachable; falling back to hostname for the queue name"
fi
WORKER_QUEUE="${WORKER_QUEUE_OVERRIDE:-sivacor.${WORKER_UUID:-$(hostname -s)}}"
echo "--- queue: ${WORKER_QUEUE} ---"

# ---- env file: docker --env-file format ----------------------------------
# Bare KEY=VALUE. NO 'export', NO quotes (quotes become part of the value).
# deploy-sivacor/.env is the opposite - it is shell-sourced and needs 'export'.
#
# Supplied secrets go in verbatim; anything left empty becomes FILL_ME so that
# preflight fails loudly rather than the worker starting with a broken broker URL.
if [ -n "$MASTER_KEY_HEX" ] && [ -n "$REDIS_PASSWORD" ]; then
  SECRETS_SUPPLIED=1
  echo "--- secrets supplied via user-data; worker will self-start ---"
else
  SECRETS_SUPPLIED=0
  echo "--- secrets NOT supplied; worker.env gets placeholders, unit left stopped ---"
fi
cat > /etc/sivacor/worker.env <<EOF
# Generated $(date -Is). Format: docker --env-file (no export, no quotes).
# Any FILL_ME below must be replaced, then:
#   sudo sivacor-worker-preflight && sudo systemctl enable --now sivacor-worker

# Must match the server byte for byte (server encrypts job secrets, worker
# decrypts). Copy from deploy-sivacor/.env on the manager.
MASTER_KEY_HEX=${MASTER_KEY_HEX:-FILL_ME}

# Same redis password as the manager, in all three.
GIRDER_WORKER_BROKER=redis://:${REDIS_PASSWORD:-FILL_ME}@${MANAGER_TENANT_IP}:6379/
GIRDER_WORKER_BACKEND=redis://:${REDIS_PASSWORD:-FILL_ME}@${MANAGER_TENANT_IP}:6379/
GIRDER_NOTIFICATION_REDIS_URL=redis://:${REDIS_PASSWORD:-FILL_ME}@${MANAGER_TENANT_IP}:6379/

# NOTE: no GPG settings here, deliberately. TRO signing runs on the MANAGER (the
# sign step is dispatched to the 'local' queue, which only the manager's
# co-located worker consumes), and since tro-utils 0.4.6 nothing outside signing
# touches a keyring. A worker holds no key material, so a compromised worker
# cannot mint a TRO. The fingerprint and passphrase live only in the
# sivacor.tro_gpg_fingerprint / _passphrase Girder settings, read server-side.

# Discovered at provision time.
GIRDER_API_URL=https://${GIRDER_HOST}/api/v1
SIVACOR_WORKER_QUEUE=${WORKER_QUEUE}
SIVACOR_EPHEMERAL_WORKER=${EPHEMERAL_WORKER}
DOCKER_HOST_TMP_ROOT=/home/${DEPLOY_USER}/volumes
GOSU_USER=${DEPLOY_UID}:${DEPLOY_GID}:${DOCKER_GID}
HOSTDIR=/

# STATA_LICENSE_HOSTPATH is deliberately NOT set here.
#
# It used to be, pointing at a file cloud-init never creates -- and because
# lib.py mounted it for every image, not just Stata, a missing license failed
# *unrelated* submissions at container create ("bind source path does not
# exist"). A worker has no license on disk and no way to get one at boot: D7
# rules out baked images and cloud secret managers, and cloud-init holds no
# Girder credential (the admin-scoped token only arrives with the task).
#
# So leaving this unset is what selects the run-time path: lib.py's
# stata_license_mount_source() fetches the license from the
# sivacor.stata_license Girder setting when a Stata image is actually requested.
# Set it only on a host that really has a license file, i.e. the manager.

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

# ---- self-shutdown supervisor (P3.3) -------------------------------------
# Powers off once this worker is demonstrably done. Poweroff, not self-delete:
# the controller reaps SHUTOFF instances, so a worker holds no OpenStack creds.
#
# THE ONE RULE: every probe that cannot answer must fall through to "busy".
# Powering off a live worker destroys a running submission and strands the job
# until the reaper notices, whereas failing to power off costs SUs and is caught
# by the controller's absolute max-lifetime sweep (P3.1 step 6). Those are not
# comparable, so the script never uses `set -e` and treats an unreachable broker,
# a wedged docker socket or an unparseable reply as "stay up".
cat > /usr/local/bin/sivacor-worker-idle-check <<PRE
#!/bin/bash
# Generated by worker-cloud-init.sh. Safe to run by hand: it only ever powers off
# when all four checks below agree, and logs its reasoning either way.
IDLE_TIMEOUT_SEC=${IDLE_TIMEOUT_SEC}
BOOT_GRACE_SEC=${BOOT_GRACE_SEC}
PRE
cat >> /usr/local/bin/sivacor-worker-idle-check <<'IDLE'
WORKER_CONTAINER=sivacor-worker
STATE=/run/sivacor-idle-since   # /run is tmpfs, so this resets on boot

log() { echo "$(date -Is) $*"; }

# Clear the idle clock and stop. Any doubt lands here.
busy() { rm -f "$STATE"; log "BUSY: $* -- staying up"; exit 0; }

# 1. Boot grace. A VM created for a queued submission must not power off before
#    it has had a chance to be handed one.
uptime_sec=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$uptime_sec" in
  ''|*[!0-9]*) busy "cannot read /proc/uptime" ;;
esac
[ "$uptime_sec" -lt "$BOOT_GRACE_SEC" ] && \
  busy "uptime ${uptime_sec}s < boot grace ${BOOT_GRACE_SEC}s"

# 2. Analysis containers. These are SIBLINGS started through the docker socket,
#    not children of the celery task, so one can outlive the task that started it
#    (P1.3 finding 9). "celery is idle" is therefore not "safe to reclaim".
if ! ps_out=$(docker ps --format '{{.Names}}' 2>&1); then
  busy "docker ps failed: ${ps_out}"
fi
others=$(printf '%s\n' "$ps_out" | grep -vx "$WORKER_CONTAINER" | grep -c .)
[ "$others" -gt 0 ] && busy "${others} analysis container(s) still running"

# 3. Celery active tasks -- ON THIS NODE ONLY. An untargeted `inspect` broadcasts
#    to every worker on the broker, including the manager's, which is never idle;
#    that would keep every VM alive forever. The node name is celery@<hostname>
#    and inside the container the hostname is the container id, so it is derived
#    in-container rather than guessed out here (it changes on restart).
#
#    Checking active tasks rather than "have I served one submission yet" is
#    deliberate: cancel_consumer is asynchronous and messages ack on receipt, so
#    a worker can be holding two (P3.2).
if ! active=$(docker exec "$WORKER_CONTAINER" sh -c \
      'celery -A girder_worker.app inspect active --json --timeout 10 -d celery@$(hostname)' 2>&1); then
  busy "celery inspect failed: ${active}"
fi
# length > 0 requires the node to have actually replied; an empty object means
# nobody answered, which is not evidence of idleness.
if ! printf '%s' "$active" \
     | jq -e 'to_entries | (length > 0) and all(.[]; .value | length == 0)' >/dev/null 2>&1; then
  busy "active task(s), or unparseable reply: ${active}"
fi

# 4. Idle long enough? Start the clock on the first idle observation.
#
#    DO NOT SHORTEN IDLE_TIMEOUT_SEC TO MAKE INSTANCES RECLAIM FASTER. A worker
#    goes genuinely idle *in the middle of its own chain*: sign_tro is the one
#    unpinned step (routing.py UNPINNED_TASKS), so it runs on the manager, and
#    upload_workspace then comes back to this worker's private queue. While the
#    manager signs -- GPG plus an RFC-3161 round trip to an external TSA -- this
#    worker has no active task, no running container, and nothing queued (celery
#    publishes a chain's next step only when the previous one finishes, so even
#    LLEN on the private queue reads zero). Powering off in that window strands
#    the submission with no package uploaded.
#
#    Observed signing takes ~1 s (.sig 13:30:44, .tsr 13:30:45 on 2026-08-01), so
#    300 s is a ~300x margin, and the two-tick minimum below adds more. That
#    margin is the whole safety story for this window -- spend it deliberately.
now=$(date +%s)
if [ ! -f "$STATE" ]; then
  echo "$now" > "$STATE"
  log "idle: starting ${IDLE_TIMEOUT_SEC}s clock"
  exit 0
fi
since=$(cat "$STATE" 2>/dev/null)
case "$since" in
  ''|*[!0-9]*) echo "$now" > "$STATE"; busy "idle clock unreadable, restarting it" ;;
esac
idle_for=$(( now - since ))
if [ "$idle_for" -lt "$IDLE_TIMEOUT_SEC" ]; then
  log "idle ${idle_for}s / ${IDLE_TIMEOUT_SEC}s"
  exit 0
fi

log "idle ${idle_for}s, no containers, no active tasks -- POWERING OFF"
systemctl poweroff
IDLE
chmod 755 /usr/local/bin/sivacor-worker-idle-check

cat > /etc/systemd/system/sivacor-worker-idle.service <<'EOF'
[Unit]
Description=SIVACOR ephemeral worker self-shutdown check
# Do not run while the worker unit is stopped/restarting: docker exec would fail
# and (correctly) report busy, but the log noise is misleading.
After=sivacor-worker.service

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/sivacor-worker-idle-check
EOF

cat > /etc/systemd/system/sivacor-worker-idle.timer <<'EOF'
[Unit]
Description=Check every 2 min whether this worker is done

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
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

echo "5. no key material on this host"
# A worker must not be able to sign. Signing is dispatched to the manager's
# 'local' queue, and since tro-utils 0.4.6 nothing else opens a keyring -- so a
# keyring here is not merely unused, it is a trust-boundary regression that
# nothing else would flag.
if [ -e /home/ubuntu/.gnupg ]; then
  bad "/home/ubuntu/.gnupg exists - workers must hold no TRS key material; remove it"
elif command -v gpg >/dev/null 2>&1 && sudo -u ubuntu gpg --list-secret-keys 2>/dev/null | grep -q .; then
  bad "a secret key is present in ubuntu's default keyring - remove it"
else
  ok "no keyring, no secret keys"
fi

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
grep -qE '^GIRDER_SIVACOR_TRO_GPG_' "$E" \
  && bad "TRO GPG settings present - signing happens on the manager; nothing reads these" \
  || ok "no GPG settings"

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

Already done (see the log for detail): packages, dirs, ${GIRDER_HOST} -> ${MANAGER_TENANT_IP},
worker image, docker GID ${DOCKER_GID}, queue ${WORKER_QUEUE}, systemd unit.

## 1. Credentials -- sudo nano /etc/sivacor/worker.env
SKIP THIS if provisioning reported "secrets supplied via user-data": the file is
already complete and the worker was started for you. Check with
'systemctl status sivacor-worker'.

Otherwise fill MASTER_KEY_HEX (from the manager's .env, must match exactly) and
the redis password in all three redis:// URLs. Format: no 'export', no quotes.
Preflight fails while any FILL_ME remains, so nothing starts half-configured.

## 2. No signing key -- nothing to do here
This host holds NO TRS key material, by design: signing runs on the manager, and
since tro-utils 0.4.6 nothing outside signing opens a keyring. So a compromised
worker cannot mint a TRO. If you find yourself creating .gnupg here, something has
regressed -- preflight check 5 fails on exactly that.

## 3. Stata license -- nothing to do here
Fetched at run time from the sivacor.stata_license Girder setting, only when a
submission actually names a Stata image. Nothing to copy onto this host, and
STATA_LICENSE_HOSTPATH is deliberately unset. If Stata submissions fail with
"this deployment has no Stata license", that setting is empty on the SERVER --
fix it there, not here.

## 4. Start
    sudo sivacor-worker-preflight
    sudo systemctl enable --now sivacor-worker
    sudo systemctl enable --now sivacor-worker-idle.timer   # unless SELF_SHUTDOWN=0
    journalctl -u sivacor-worker -f

## 4b. This VM powers itself off when done (SELF_SHUTDOWN=${SELF_SHUTDOWN})
Every 2 min sivacor-worker-idle-check asks: past ${BOOT_GRACE_SEC}s uptime, no
analysis containers, no active celery tasks, idle ${IDLE_TIMEOUT_SEC}s? Then
'systemctl poweroff', and the controller reaps the SHUTOFF instance. So an
instance vanishing on you is expected, not a crash. To debug without that:
    sudo systemctl stop sivacor-worker-idle.timer
    sudo /usr/local/bin/sivacor-worker-idle-check   # dry-ish: logs its reasoning
    journalctl -u sivacor-worker-idle -f            # why it stayed up

## 5. On the manager
Set SIVACOR_MANAGER_QUEUES=local,sivacor.static-01 so it stops taking
submissions, then confirm the split:
    celery -A girder_worker.app inspect active_queues
    # manager: local, sivacor.static-01   worker: sivacor, ${WORKER_QUEUE}
EOF
chown "$DEPLOY_UID":"$DEPLOY_GID" /home/"$DEPLOY_USER"/NEXT_STEPS.md

# ---- start, if we were given everything needed ---------------------------
# Hands-off boot: with secrets supplied nothing is left for a human, so waiting for
# one would just mean an instance that never consumes anything. Preflight gates the
# start -- it catches an unreachable broker (security group), unreachable Girder
# (floating-ip hairpin) and an unusable docker socket, each of which otherwise looks
# like a worker that starts and silently does nothing. A preflight failure is NOT
# fatal to provisioning: the VM stays up so the log can be read, and an autoscaler
# should reap anything that never registers with celery (P3.4 circuit breaker).
if [ "$SECRETS_SUPPLIED" = 1 ]; then
  printf '\n*** SIVACOR worker: provisioned and starting automatically ***\n\n' > /etc/motd
  if sivacor-worker-preflight; then
    systemctl enable --now sivacor-worker
    echo "--- worker started; queue ${WORKER_QUEUE} ---"
    # Only after the worker is actually up: the timer's first fire is 2 min from
    # boot, and an enabled timer against a worker that never started would just
    # log "busy" until the controller's max-lifetime sweep took the VM anyway.
    if [ "$SELF_SHUTDOWN" = 1 ]; then
      systemctl enable --now sivacor-worker-idle.timer
      echo "--- self-shutdown armed: idle ${IDLE_TIMEOUT_SEC}s, boot grace ${BOOT_GRACE_SEC}s ---"
    else
      echo "--- self-shutdown DISABLED (SELF_SHUTDOWN=${SELF_SHUTDOWN}); reap this VM by hand ---"
    fi
  else
    printf '\n*** SIVACOR worker: PREFLIGHT FAILED - see /var/log/sivacor-provision.log ***\n\n' > /etc/motd
    echo "!! preflight failed; worker NOT started"
  fi
else
  printf '\n*** SIVACOR worker: read ~/NEXT_STEPS.md, credentials still needed ***\n\n' > /etc/motd
fi

echo "=== finished $(date -Is): queue=${WORKER_QUEUE} docker_gid=${DOCKER_GID} secrets=${SECRETS_SUPPLIED} ==="
