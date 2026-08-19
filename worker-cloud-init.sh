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

# SIZE BUDGET -- THIS FILE IS user_data. Nova rejects it over 65535 bytes *base64*,
# and the autoscaler injects ~480 more on top. Comments cost real bytes here, unlike
# anywhere else in this workspace: on 2026-08-12 a comment-heavy commit put it 65
# bytes over and NO worker could be created until it was trimmed. Check before
# pushing:  base64 -w0 worker-cloud-init.sh | wc -c
# Long-form rationale belongs in development_notes/, which this file points at.

set -euo pipefail
exec > >(tee -a /var/log/sivacor-provision.log) 2>&1
echo "=== provisioning started $(date -Is) ==="

# Say so loudly, on the serial console, if any of this fails. Under `set -e` an
# abort is otherwise near-silent: cloud-init logs one generic `Failed to run module
# scripts_user` and the instance sits ACTIVE with no celery and -- because the
# systemd units below were never written -- no self-shutdown supervisor either.
# On 2026-08-02 that cost a VM for a whole run and stalled a submission behind it,
# and answering "did this provision?" meant reading 100 kB of console log for an
# absence. `openstack console log show <id> | grep SIVACOR-PROVISION` now answers it.
# This is diagnosis only: the controller decides with the readiness marker the
# worker publishes once celery is actually up (plan D9), not with this line.
trap 'rc=$?; echo "=== SIVACOR-PROVISION FAILED (exit $rc) at line $LINENO: ${BASH_COMMAND} ==="; exit $rc' ERR

# ---- config: review these before launching -------------------------------
# WORKER_IMAGE is normally INJECTED and this default should never be reached from a
# `make dev` deployment: the Makefile derives SIVACOR_WORKER_IMAGE from
# GIRDER_SIVACOR_IMAGE, so the worker and the manager are the same digest by
# construction rather than by anyone remembering. It stays here for a hand-pasted run.
#
# It used to be `:distributed`, on the convention that the tag tracked the branch so
# worker and manager were provably the same build. That convention died when the branch
# merged: docker.yml pushes only `latest`, only from `main`, so nothing would ever
# rebuild `:distributed` again -- it froze at a hand-push of 2026-08-02 while the manager
# moved on, and a fresh VM would have booted increasingly stale code with no signal at
# all. `latest` is the honest last resort; a digest from the Makefile is the real answer.
#
# launch-worker.py replaces the marker line below with assignments. Everything in
# this block therefore uses ${VAR:-default}, so an injected value wins and a
# hand-pasted run still works. Keep the marker on its own line, spelled exactly.
#__SIVACOR_INJECT__

WORKER_IMAGE="${WORKER_IMAGE:-docker.io/xarthisius/girder-sivacor:latest}"
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
# What celery subscribes to. Empty -> `sivacor,<this VM's private queue>`, i.e. both
# the shared dispatch queue and its own, which is what every worker has always done.
#
# Set `SIVACOR_WORKER_QUEUES=private` in the deployment's .env -- injected by the
# controller -- once targeted assignment is armed there and nothing publishes to
# `sivacor` any more (worker_sizing_plan.md P2, rollout step 4). See the case statement
# below for why the value is a word and not a queue list. It is a
# variable rather than an edit to the line below because THIS FILE IS SHARED: one
# checkout is bind-mounted by the mirror and by production, which are at different
# stages of that rollout. Narrowing it in the file would take effect on production's
# next pull, while production is still flag-off and publishing to `sivacor` -- every
# submission would strand with the fleet reading healthy. Same reasoning, and the same
# shape, as SIVACOR_MANAGER_QUEUES for the manager's own worker.
#
# The default is applied further down, once WORKER_QUEUE actually has a value.
WORKER_QUEUES="${WORKER_QUEUES:-}"
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
# Consecutive ticks celery may be unreachable before the VM reclaims itself anyway.
# At the 2 min timer that is ~16 min. See the "unreachable" note in the supervisor:
# a worker whose broker connection is dead cannot receive tasks, cannot finish a
# chain and cannot be told anything -- treating that as "busy" forever is what left
# two VMs immortal on 2026-08-01. Deliberately far longer than any signing round
# trip (~1 s observed, 300 s timeout), because that is the one window where a
# healthy worker is legitimately idle mid-chain.
UNREACHABLE_TICKS="${UNREACHABLE_TICKS:-8}"
# Consecutive unreachable ticks before trying to RECOVER the worker -- one
# `docker restart sivacor-worker` -- instead of going straight to poweroff. 0
# disables recovery and restores the pre-2026-08-11 behaviour.
#
# Why this exists. On 2026-08-11 a worker's celery MainProcess died silently at
# 15:09 while its pool worker ran Stata for another two hours. The child finished
# at 17:13, published the chain's next step (`LLEN 1` on the private queue), and
# nothing consumed it: the parent was gone. Heartbeats had kept flowing the whole
# time because they are HTTP calls made by the *child*, so Girder saw a healthy
# submission until the moment it had none. Restarting the container by hand
# recovered it completely -- the queued task was consumed, the chain continued,
# and the submission reached a truthful terminal state, preserving 2 h 52 m of
# completed compute that would otherwise have been reaped as "no heartbeat".
# Three submissions were lost this way on 2026-08-10/11 before anyone was watching
# at the right moment. This makes that recovery automatic.
#
# Safe by construction: the unreachable path is only reached once `docker ps` has
# succeeded AND reported zero analysis containers, so a restart can never
# interrupt a running analysis. It also cannot fire during the legitimate
# mid-chain idle window (sign_tro on the manager), because there celery is healthy
# and answers `inspect` with "idle" -- that is `busy`/idle, never `unreachable`.
#
# THE RESIDUAL RISK, stated plainly: a container-less pool task -- create_workspace
# unzipping a multi-GB package, prune, upload_workspace -- runs with no analysis
# container, so if the parent wedges during one, a restart kills the child's
# in-flight work (celery acks on receipt, so the message is already gone). The
# workspace-activity check below defers the restart while anything is still
# writing, which covers the common case; it cannot cover a child stalled on a
# network write. Weigh that against the alternative, which is losing the
# submission every time.
RECOVER_TICKS="${RECOVER_TICKS:-3}"
DEPLOY_USER="ubuntu"; DEPLOY_UID=1000; DEPLOY_GID=1000

# ---- secrets: filled in by the controller; empty = provision manually --------
# See the SECRETS note in the header before changing how these are delivered.
# Both must match the manager byte for byte. When BOTH are set, this script
# writes a complete worker.env and starts the worker itself -- no manual step.
MASTER_KEY_HEX="${MASTER_KEY_HEX:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

# ---- packages ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# Wait for the dpkg lock rather than failing on it. `unattended-upgrades` starts
# automatically on a fresh Ubuntu boot and routinely still holds the lock when
# cloud-init reaches this point, which is a race we lose roughly one boot in
# three. It cost a whole VM on 2026-08-02 (run 6): apt exited non-zero here,
# cloud-init reported `Failed to run module scripts_user`, and because this step
# precedes the systemd units, the instance came up with no celery AND no
# self-shutdown supervisor -- so it could neither work nor reclaim itself, and
# sat ACTIVE absorbing a submission's worth of controller capacity until the 30 h
# max-lifetime sweep. `DPkg::Lock::Timeout` (apt >= 2.0) makes apt block instead.
APT_LOCK_WAIT="-o DPkg::Lock::Timeout=600"
apt-get $APT_LOCK_WAIT update -q
# No gnupg: since tro-utils 0.4.6 the keyring is only touched when signing, and
# signing runs on the manager. A worker needs no key material and no gpg binary.
apt-get $APT_LOCK_WAIT install -y -q docker.io redis-tools ca-certificates curl jq
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
# Resolved here, not in the header: every branch names WORKER_QUEUE, which does not
# exist until the line above has run.
#
# `private` is spelled as a word rather than as a queue list because the list cannot be
# written down off-box: the private queue is `sivacor.<this VM's uuid>`, known only
# here. A deployment that tried to say it literally -- `sivacor.$WORKER_UUID` in .env --
# would get it verbatim, since the controller shell-quotes injected values, and the
# worker would subscribe to a queue nothing ever publishes to and sit idle looking
# healthy. That is the same class of silent failure this variable exists to prevent, so
# the common case is one unmistakable word and anything else is checked below.
case "${WORKER_QUEUES}" in
  "")        WORKER_QUEUES="sivacor,${WORKER_QUEUE}" ;;
  private)   WORKER_QUEUES="${WORKER_QUEUE}" ;;
  *)         : ;;   # verbatim, for a hand-made debug worker
esac
case ",${WORKER_QUEUES}," in
  *",${WORKER_QUEUE},"*) : ;;
  *) echo "!! WORKER_QUEUES (${WORKER_QUEUES}) does not include this VM's own queue"
     echo "!! ${WORKER_QUEUE} -- nothing the controller assigns to it will be consumed." ;;
esac
echo "--- queue: ${WORKER_QUEUE} ---"
echo "--- subscribing to: ${WORKER_QUEUES} ---"

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

# ---- py-spy, on the host -------------------------------------------------
# py-spy must be a HOST binary: dump_wedge_state() runs here as root against
# host-namespace pids. In-container would need CAP_SYS_PTRACE, and `docker exec`
# would make the probe depend on the container being answerable -- the mistake the
# celery `inspect` check already made. https + pinned sha256 because this runs as
# root; a checksum failure means someone replaced the upload. Best-effort: without
# it a worker still boots, still recovers, and dumps kernel state only.
# Rationale: development_notes/incidents/2026-08-11-worker-wedge.md item 12.
PY_SPY_URL="https://use.yt/upload/c90d5c7c"
PY_SPY_SHA256="9b4d1f39b2a47ae44f4c6a46f615dcc0287d7755beba5065f32391951e07d594"
# -o and never -JLO: -J takes the filename from the server and -O writes it to the
# current directory, neither of which a boot script should delegate.
if curl -fsSL --max-time 120 -o /usr/local/bin/py-spy.new "$PY_SPY_URL" 2>/dev/null \
   && printf '%s  %s\n' "$PY_SPY_SHA256" /usr/local/bin/py-spy.new | sha256sum -c --status; then
  chmod 755 /usr/local/bin/py-spy.new
  mv /usr/local/bin/py-spy.new /usr/local/bin/py-spy
  echo "py-spy on host: $(/usr/local/bin/py-spy --version 2>&1 | head -1) from ${PY_SPY_URL}"
else
  rm -f /usr/local/bin/py-spy.new
  echo "!! py-spy unavailable (download failed or checksum mismatch) -- wedge dumps will be kernel-only"
fi

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
    --queues=${WORKER_QUEUES} \\
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
UNREACHABLE_TICKS=${UNREACHABLE_TICKS}
RECOVER_TICKS=${RECOVER_TICKS}
# Host side of the worker's -v ...:/tmp bind mount, so in-flight work can be seen
# without going through the container at all -- see workspace_activity().
WORKER_TMP_HOSTPATH=/home/${DEPLOY_USER}/volumes/tmp
PRE
cat >> /usr/local/bin/sivacor-worker-idle-check <<'IDLE'
WORKER_CONTAINER=sivacor-worker
# Extracted from the worker image at boot; absent is a supported state, see
# dump_wedge_state(). A host binary on purpose: this script runs on the host.
PY_SPY=/usr/local/bin/py-spy
STATE=/run/sivacor-idle-since   # /run is tmpfs, so both reset on boot
FAILS=/run/sivacor-probe-failures
RECOVERED=/run/sivacor-recovery-attempted   # one restart per wedge, not per tick

log() { echo "$(date -Is) $*"; }

# Everything we will wish we had after the VM is gone. Printed, not saved: /run is
# tmpfs and the disk is about to be destroyed either way, whereas stdout reaches
# journal+console, and the console survives long enough for the controller to
# capture it on the way past (sivacor-autoscaler's pre-delete diagnostics).
#
# The question this is here to answer: when celery stops answering, is the process
# blocked in the kernel (`D` state, with a wchan naming what on) or starved of
# memory (PSI `some`/`full` climbing)? On 2026-08-11 that could not be settled --
# TCP keepalive was armed and the socket healthy, so the connection was not the
# problem, and by the time anyone looked the process had been restarted.
#
# NOTHING HERE READS CONTAINER LOGS, deliberately. A celery result line can carry
# the submission's `encrypted_secrets` and `wrapped_job_key`, which is why the
# inspect payload upstream is reduced to a count before it is logged. Process
# state, memory pressure and kernel messages carry no job material.
dump_wedge_state() {
  # `.State.Pid` is the container's PID 1 = **tini**, not celery (the unit runs
  # `--entrypoint /usr/bin/tini`). Profiling it wasted the only dump of a real wedge
  # on 2026-08-12: tini always sleeps in do_sigtimedwait and reports `Threads: 1`.
  # Resolve the Python child. See notes item 12.
  tini_pid=$(docker inspect -f '{{.State.Pid}}' "$WORKER_CONTAINER" 2>/dev/null)
  # Missing container prints nothing, stopped prints 0. Both must become "no pid":
  # `pgrep -P 0` returns **PID 1**, so a defaulted `${tini_pid:-0}` would describe
  # systemd as celery and point py-spy at init. Pinned by tests/wedge-dump-test.sh.
  case "${tini_pid:-}" in ''|0|*[!0-9]*) tini_pid="" ;; esac
  celery_pid=""
  if [ -n "$tini_pid" ]; then
    celery_pid=$(pgrep -P "$tini_pid" -f celery 2>/dev/null | head -1)
    # Fall back to tini's first child: better a slightly wrong pid than none, and if
    # the cmdline ever stops saying "celery" this still finds the process that matters.
    [ -z "$celery_pid" ] && celery_pid=$(pgrep -P "$tini_pid" 2>/dev/null | head -1)
  fi
  log "---- wedge diagnostics: tini ${tini_pid:-UNKNOWN}, celery MainProcess ${celery_pid:-UNKNOWN} ----"
  if [ -n "$tini_pid" ]; then
    # One line of context. tini idles in do_sigtimedwait forever, by design, so it
    # is only here to prove the shape of the tree and never as evidence.
    ps -o pid,ppid,stat,wchan:24,etime,pcpu,rss,cmd -p "$tini_pid" 2>&1 | sed 's/^/    /'
  fi
  if [ -n "$celery_pid" ]; then
    # STAT is the payload: `D` means uninterruptible sleep, which no signal can
    # clear and only a restart escapes. `S` with 0% CPU means it is waiting for
    # something that is not coming -- a deadlock or a lost wakeup. WCHAN names the
    # kernel function it is in.
    ps -o pid,ppid,stat,wchan:24,etime,pcpu,rss,cmd -p "$celery_pid" 2>&1 | sed 's/^/    /'
    # Children: the billiard pool worker(s) -- the pipe to the parent is a prime
    # suspect for the lost wakeup.
    ps -o pid,stat,wchan:24,etime,pcpu,rss,cmd --ppid "$celery_pid" 2>&1 | sed 's/^/    /' | head -12
    sed -n 's/^\(State\|Threads\|VmRSS\):/    &/p' "/proc/$celery_pid/status" 2>/dev/null
    # Per THREAD: a deadlock is a property of a thread. Usually one line (MainProcess
    # drives an event loop, not a thread pool), but when it is not, the odd thread out
    # is the whole answer.
    { echo "    threads of $celery_pid:"
      for t in "/proc/$celery_pid/task/"*; do
        [ -d "$t" ] || continue
        printf '      tid %s %-16s wchan=%s\n' "${t##*/}" \
          "$(cat "$t/comm" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
      done | head -16; }
    # Root-only and often "0xffffffffffffffff [<0>]" for a healthy process; when it
    # is not, it names the exact blocking call.
    { echo "    /proc/$celery_pid/stack:"; head -12 "/proc/$celery_pid/stack" 2>&1 | sed 's/^/      /'; }
  fi
  # PSI. `full` above zero means every task was stalled on memory -- the direct
  # test of the starvation theory, and it costs nothing to read.
  { echo "    /proc/pressure/memory:"; sed 's/^/      /' /proc/pressure/memory 2>&1; }
  free -m 2>&1 | sed 's/^/    /'
  df -h / 2>&1 | tail -1 | sed 's/^/    /'
  # hung_task_timeout_secs fires at 120 s in D state and names the process.
  dmesg -T 2>/dev/null | grep -iE "oom|out of memory|killed process|hung task|blocked for more than" \
    | tail -8 | sed 's/^/    /'
  # The Python frame, the entire point: kernel state can only say "blocked in an
  # interruptible wait", and kombu's broker read and the billiard pipe look identical
  # from there. LAST and time-boxed -- it is the only part that can hang, and a hang
  # would be killed with the whole oneshot check, taking the cheap evidence with it.
  if [ -n "$celery_pid" ] && [ -x "$PY_SPY" ]; then
    { echo "    py-spy dump (Python stacks, all threads):"
      timeout 20 "$PY_SPY" dump --pid "$celery_pid" 2>&1 | head -60 | sed 's/^/      /'; }
  elif [ -n "$celery_pid" ]; then
    echo "    py-spy: ${PY_SPY} absent -- kernel state only, no Python frames"
  fi
  log "---- wedge diagnostics end ----"
}

# Is anything still writing? A pool task with no analysis container -- unzipping a
# package, pruning, uploading -- is invisible to the container check above, and
# restarting on top of one loses its work (celery acks on receipt). Recent mtimes
# under /tmp, where tmp_dir and workspace_dir both live (lib.py), are the cheapest
# evidence that a child is still doing something. It cannot see a child stalled on
# a network write, which is why this defers recovery rather than cancelling it:
# the ticks keep counting and the poweroff net still backstops us.
#
# Read from the HOST side of the worker's `-v .../volumes/tmp:/tmp` bind mount
# rather than through `docker exec`. Two reasons, both learned here: the probe must
# not depend on `find` existing in the analysis-agnostic worker image, and more
# importantly it must not depend on the container being answerable at all -- this
# runs precisely when the worker is not answering, and a second probe sharing that
# failure mode is how the original `inspect` check became ambiguous in the first
# place. GNU find is guaranteed on the Ubuntu host.
#
# Echoes active | quiet | unknown. `unknown` is a distinct answer on purpose: a
# two-state version would report "quiet" when it simply could not look, and this
# safety check would be silently inert -- the same shape of bug as an unarmed
# readiness marker. Say so instead, and let the caller decide in the open.
workspace_activity() {
  [ -d "$WORKER_TMP_HOSTPATH" ] || { echo unknown; return; }
  # -mindepth 1 is load-bearing: without it the mount point matches itself, and its
  # own mtime bumps whenever any workspace directory is created or removed -- so
  # every wedge that happened to follow a workspace change would read as "active"
  # and defer recovery until the poweroff net caught it. That is the bug this
  # check exists to avoid, arriving through the check itself.
  if find "$WORKER_TMP_HOSTPATH" -mindepth 1 -maxdepth 3 -newermt '-3 minutes' \
       -print -quit 2>/dev/null | grep -q .; then
    echo active
  else
    echo quiet
  fi
}

# THREE outcomes, not two. The original had only `busy`, which cleared the idle
# clock unconditionally -- so a probe that merely *failed* threw away up to
# IDLE_TIMEOUT_SEC of accumulated evidence, and a persistently failing probe reset
# it on every tick, forever. That is precisely how sivacor-worker-3a052548 became
# immortal on 2026-08-01: it was on the very tick that would have powered it off
# when `celery inspect` started failing, and every later tick wiped the clock again.
#
#   busy        -- positive evidence of work. Clear the clock; that is correct.
#   blocked     -- cannot observe at all. Keep the clock, keep the failure count
#                  out of it, stay up. Costs one tick, not the whole clock.
#   unreachable -- celery specifically will not answer, but we have already
#                  confirmed uptime past the grace and no analysis containers.
#                  Count it; reclaim once it is clearly not coming back.
# $RECOVERED is cleared here too: a worker that has answered again is healthy, and
# a *later* wedge deserves its own recovery attempt rather than inheriting a spent
# marker from an earlier one.
busy()    { rm -f "$STATE" "$FAILS" "$RECOVERED"; log "BUSY: $* -- staying up"; exit 0; }
blocked() { log "BLOCKED: $* -- staying up, idle clock preserved"; exit 0; }

# 1. Boot grace. A VM created for a queued submission must not power off before
#    it has had a chance to be handed one.
uptime_sec=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$uptime_sec" in
  ''|*[!0-9]*) blocked "cannot read /proc/uptime" ;;
esac
[ "$uptime_sec" -lt "$BOOT_GRACE_SEC" ] && \
  busy "uptime ${uptime_sec}s < boot grace ${BOOT_GRACE_SEC}s"

# 2. Analysis containers. These are SIBLINGS started through the docker socket,
#    not children of the celery task, so one can outlive the task that started it
#    (P1.3 finding 9). "celery is idle" is therefore not "safe to reclaim".
# A broken docker socket is `blocked`, not `busy`: we cannot see containers, so we
# must not reclaim -- but it is not evidence of work either, and it must not gate
# the unreachable counter below, which assumes this check actually passed.
if ! ps_out=$(docker ps --format '{{.Names}}' 2>&1); then
  blocked "docker ps failed: ${ps_out}"
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
#    THE PROBE SHARES A FAILURE MODE WITH WHAT IT PROBES. `inspect` is a broadcast
#    over the broker, so a worker whose *broker connection* has died cannot answer
#    it -- and that is indistinguishable, from here, from a worker that is busy.
#    Observed 2026-08-01 on sivacor-worker-3a052548: fresh connections to Redis
#    worked (`redis-cli ping` -> NOAUTH), the container was up and `docker exec`
#    fine, but celery's established socket was half-open, so it answered nothing
#    and even its own cold shutdown hung. Hence `unreachable` rather than `busy`:
#    a worker that cannot be reached over the broker also cannot be *given* work,
#    so sustained unreachability is evidence for reclaiming, not against.
unreachable() {
  n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  echo "$n" > "$FAILS"
  if [ "$n" -ge "$UNREACHABLE_TICKS" ]; then
    # Safe to act on: we are past the boot grace and have already confirmed there
    # are no analysis containers, both checked above this point.
    #
    # Dumped again even though recovery already dumped once: this is the state
    # *after* a restart failed to help, which is the more interesting of the two
    # and the last chance to record anything at all.
    dump_wedge_state
    log "celery unreachable for $n consecutive ticks, no containers -- POWERING OFF ($*)"
    systemctl poweroff
    exit 0
  fi

  # Try to fix it before reclaiming it. A restart costs ~30 s and recovers the
  # submission; a poweroff destroys it. Ordered after the poweroff check so a
  # RECOVER_TICKS misconfigured above UNREACHABLE_TICKS still ends in a reclaim
  # rather than an immortal VM.
  if [ "${RECOVER_TICKS:-0}" -gt 0 ] && [ "$n" -ge "$RECOVER_TICKS" ] && [ ! -f "$RECOVERED" ]; then
    case "$(workspace_activity)" in
      active)
        # Something is still writing, so a child is still working even though
        # celery cannot say so. Do not restart on top of it.
        log "RECOVERY DEFERRED ($n/$UNREACHABLE_TICKS): /tmp written to in the last 3 min"
        exit 0 ;;
      unknown)
        # Proceed rather than defer: deferring forever loses the submission, which
        # is the outcome this whole branch exists to prevent. But never silently.
        log "RECOVERY: cannot see $WORKER_TMP_HOSTPATH to check for in-flight work -- restarting anyway" ;;
    esac
    dump_wedge_state
    : > "$RECOVERED"
    log "RECOVERY ($n/$UNREACHABLE_TICKS): restarting $WORKER_CONTAINER -- celery is deaf but this VM may still hold a queued task"
    # `systemctl restart`, NOT `docker restart`. The unit runs `docker run --rm` in
    # the foreground under Restart=always, so a `docker restart` removes the
    # container, drops the foreground process, and leaves systemd to notice and
    # rebuild it ~10 s later via ExecStartPre -- the right outcome by luck, through
    # a path that races itself. (That is what the manual recovery on 2026-08-11
    # actually did.) systemctl runs ExecStop -> ExecStartPre -> ExecStart in order.
    if out=$(systemctl restart "$WORKER_CONTAINER".service 2>&1); then
      # Deliberately not verified here. celery needs ~30 s to reconnect and the
      # next tick is 2 min away, so let the normal probe decide: a recovered
      # worker answers and goes busy/idle, a dead one keeps counting to poweroff.
      log "RECOVERY: restart issued; the next tick decides whether it took"
    else
      log "RECOVERY FAILED: systemctl restart said: $(printf '%s' "$out" | head -c 200)"
    fi
    exit 0
  fi

  log "UNREACHABLE ($n/$UNREACHABLE_TICKS): $* -- staying up, idle clock preserved"
  exit 0
}

if ! active=$(docker exec "$WORKER_CONTAINER" sh -c \
      'celery -A girder_worker.app inspect active --json --timeout 10 -d celery@$(hostname)' 2>&1); then
  # Truncated for the same reason the payload is never logged below: on failure
  # this is celery's error text, but do not bet the journal on that.
  unreachable "celery inspect failed: $(printf '%s' "$active" | head -c 200)"
fi
#    NEVER LOG $active. The reply is the full task payload, ~1.3 KB including the
#    submission's `encrypted_secrets` and `wrapped_job_key` -- printing it puts job
#    secret material in the journal on every tick of a running submission, routing
#    around the redaction lib.py applies everywhere else. Reduce to a count and
#    task names first, then log only that.
#
#    Three outcomes, deliberately distinguished: "noreply" (an empty object -- the
#    node did not answer, which is NOT evidence of idleness), "idle", or a count.
#    An earlier version collapsed them into one message that read "active task(s),
#    or unparseable reply" and then dumped the payload, which was both misleading
#    and the leak above.
verdict=$(printf '%s' "$active" | jq -r '
  to_entries as $e
  | if ($e | length) == 0 then "noreply"
    else ([$e[].value[]?]) as $t
      | if ($t | length) == 0 then "idle"
        else "\($t | length):\([$t[].name | sub(".*\\.";"")] | join(","))"
        end
    end' 2>/dev/null)
case "$verdict" in
  # A real answer: the node is reachable, so forget any earlier failures, and fall
  # through to the idle clock. Note this clears $FAILS but NOT $STATE -- the clock
  # must keep accumulating across ticks, that is the whole point of it.
  idle)     rm -f "$FAILS" ;;
  # Same class as the inspect failing outright: the node did not answer. It is not
  # evidence of idleness, and it is not evidence of work either.
  noreply)  unreachable "celery inspect returned no reply" ;;
  # The only branch that is positive evidence of work.
  [0-9]*)   busy "active task(s) ${verdict}" ;;
  # Reachable but unintelligible -- do not count it towards reclaiming, since we
  # cannot say the node is unreachable, and do not treat it as work either.
  *)        blocked "could not parse celery reply" ;;
esac

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
  # Corrupt state file: drop it so the next tick starts a fresh clock. (The old
  # code wrote $now here and then had busy() immediately delete it -- same net
  # effect, but it read as if the clock were being preserved.) Not `busy`: a
  # damaged file is not evidence of work, and must not clear the failure count.
  ''|*[!0-9]*) rm -f "$STATE"; blocked "idle clock unreadable, restarting it" ;;
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
# Also to the serial console, so `openstack console log show <id>` answers "why is
# this worker still up?" with NO access to the box. Learned 2026-08-01: a worker
# stayed alive after finishing two submissions and the fleet had been launched
# without a keypair, so the journal -- the only place the reason existed -- was
# unreachable. Cheap insurance on a fleet whose whole point is being disposable:
# every line here is one short sentence, at most one per 2 min per VM, and the
# payload that must never be logged is already reduced to a count upstream.
StandardOutput=journal+console
StandardError=journal+console
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
instance vanishing on you is expected, not a crash.

It also powers off if celery has been UNREACHABLE for ${UNREACHABLE_TICKS}
consecutive ticks with no analysis containers -- a worker whose broker connection
has died cannot be given work, so staying up would strand the VM until the
controller's 30 h cap. Each tick logs one of BUSY (real work, clock cleared),
BLOCKED (cannot observe, clock kept), UNREACHABLE (n/N, clock kept) or the idle
countdown, so the journal says exactly which it was. To debug without any of it:
    sudo systemctl stop sivacor-worker-idle.timer
    sudo /usr/local/bin/sivacor-worker-idle-check   # dry-ish: logs its reasoning
    journalctl -u sivacor-worker-idle -f            # why it stayed up
    openstack console log show <id>                 # same, with no ssh access

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
