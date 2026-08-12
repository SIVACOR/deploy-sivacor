#!/bin/bash
# Tests dump_wedge_state() from worker-cloud-init.sh against a real process tree
# shaped like the worker's: a tini-like parent with a multi-threaded Python child.
#
# WHY THIS FILE IS COMMITTED. Its predecessor -- a 7-scenario harness for the
# supervisor's tick/recovery logic -- was written into a session scratchpad under
# /tmp on 2026-08-11 and wiped overnight, along with the console archive of the
# wedge it was written for. A test that only ever existed in /tmp is a test you
# have to write twice.
#
# WHAT IT GUARDS. `docker inspect -f '{{.State.Pid}}'` returns the container's
# PID 1, which is tini, not celery. Reading /proc/<that>/ made the one dump of a
# real wedge (2026-08-12 04:39Z) useless: it described tini asleep in
# do_sigtimedwait and reported `Threads: 1`, which reads as "nothing here could
# deadlock", while the Python MainProcess sat in wait_woken one level down.
# Scenario 2 is that bug; it fails if the resolution ever regresses.
#
# Runs as a normal user. /proc/<pid>/stack and dmesg need root and will print
# permission errors into the dump -- that is fine and is not asserted on. The
# real-py-spy scenario needs root to ptrace, so it is skipped without sudo.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CLOUD_INIT=$HERE/../worker-cloud-init.sh
TMP=$(mktemp -d)
PASS=0
FAIL=0
SKIP=0

TREE_PIDS=()
# Kill the Python child explicitly, not just its parent: killing the fake tini
# leaves the grandchild orphaned and running, and an orphan that inherited this
# script's stdout holds the pipe open forever -- `... | tail` then never sees EOF
# and the whole run looks like a hang with no output. Learned the hard way.
kill_trees() {
    local p
    for p in "${TREE_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    TREE_PIDS=()
}
cleanup() { kill_trees; rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }

# --- the code under test, lifted from the shipped script -------------------
# Extracted rather than duplicated, so this cannot drift from what deploys.
eval "$(awk '/^dump_wedge_state\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$CLOUD_INIT")"
if ! declare -f dump_wedge_state >/dev/null; then
    echo "could not extract dump_wedge_state() from $CLOUD_INIT" >&2
    exit 2
fi
log() { echo "$*"; }
WORKER_CONTAINER=sivacor-worker

# --- a process tree shaped like the worker's -------------------------------
# Several threads on purpose: a single-threaded target could not tell the
# difference between reading the Python process and reading tini.
cat > "$TMP/celery" <<'PY'
import threading, time
for _ in range(3):
    threading.Thread(target=lambda: time.sleep(900), daemon=True).start()
time.sleep(900)
PY
cp "$TMP/celery" "$TMP/worker"   # same program, cmdline without the word "celery"

start_tree() {   # $1 = script name to exec, sets FAKE_TINI / PY_PID
    # >/dev/null is load-bearing, not tidiness: the tree must not inherit this
    # script's stdout (see kill_trees).
    bash -c "python3 '$TMP/$1' --app=girder_worker.app worker --concurrency=1 & wait" \
        >/dev/null 2>&1 &
    FAKE_TINI=$!
    PY_PID=""
    for _ in $(seq 1 60); do
        PY_PID=$(pgrep -P "$FAKE_TINI" 2>/dev/null | head -1)
        [ -n "$PY_PID" ] && grep -q '^Threads:' "/proc/$PY_PID/status" 2>/dev/null && break
        sleep 0.3
    done
    [ -n "$PY_PID" ] || { echo "could not start test tree" >&2; exit 2; }
    TREE_PIDS+=("$FAKE_TINI" "$PY_PID")
}

# --- fake docker: only `inspect -f {{.State.Pid}}` is used -----------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/bin/bash
[ "$1" = inspect ] || exit 0
[ -n "${FAKE_PID:-}" ] || exit 1     # emulate an unresolvable container
echo "$FAKE_PID"
SH
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH"

# --- stub py-spy that records the pid it was pointed at --------------------
cat > "$TMP/bin/py-spy-stub" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
    [ "$1" = --pid ] && { echo "$2" > "$PYSPY_PID_FILE"; }
    shift
done
echo "STUB_PYSPY_OUTPUT"
SH
chmod +x "$TMP/bin/py-spy-stub"

cat > "$TMP/bin/py-spy-hang" <<'SH'
#!/bin/bash
sleep 60
SH
chmod +x "$TMP/bin/py-spy-hang"

echo "wedge-dump-test: dump_wedge_state() from $(basename "$CLOUD_INIT")"
echo

# ==========================================================================
echo "process-tree resolution"
start_tree celery
export FAKE_PID=$FAKE_TINI
export PYSPY_PID_FILE=$TMP/pyspy.pid
PY_SPY=$TMP/bin/py-spy-stub
out=$(dump_wedge_state 2>&1)

# 1. names both pids, and the celery pid is the Python child
if grep -q "tini $FAKE_TINI, celery MainProcess $PY_PID" <<<"$out"; then
    ok "resolves tini ($FAKE_TINI) and the Python MainProcess ($PY_PID) separately"
else
    bad "resolves tini and the Python MainProcess separately" "$(grep 'wedge diagnostics:' <<<"$out")"
fi

# 2. THE ITEM-12 REGRESSION: Threads must come from Python, not tini.
threads=$(sed -n 's/^ *Threads: *//p' <<<"$out" | head -1)
if [ "${threads:-0}" -gt 1 ]; then
    ok "reports the Python process's thread count (Threads: $threads, not tini's 1)"
else
    bad "reports the Python process's thread count" "got Threads: '${threads:-none}' -- reading tini again?"
fi

# 3. per-thread wchan lines
tids=$(grep -c '^ *tid [0-9]' <<<"$out")
if [ "$tids" -gt 1 ]; then
    ok "lists per-thread wchan ($tids threads)"
else
    bad "lists per-thread wchan" "found $tids tid lines"
fi

# 4. py-spy is pointed at the Python pid, never tini's
recorded=$(cat "$TMP/pyspy.pid" 2>/dev/null)
if [ "$recorded" = "$PY_PID" ]; then
    ok "invokes py-spy against the Python pid ($PY_PID)"
elif [ "$recorded" = "$FAKE_TINI" ]; then
    bad "invokes py-spy against the Python pid" "it was pointed at tini ($FAKE_TINI) -- item 12 all over again"
else
    bad "invokes py-spy against the Python pid" "recorded '$recorded', expected $PY_PID"
fi

# 5. cheap evidence is present regardless
if grep -q '/proc/pressure/memory' <<<"$out" && grep -q 'wedge diagnostics end' <<<"$out"; then
    ok "still emits PSI/free/df and terminates the block"
else
    bad "still emits PSI/free/df and terminates the block"
fi

# ==========================================================================
echo
echo "degradation"

# 6. py-spy absent -> say so, keep the kernel evidence, exit clean
PY_SPY=$TMP/bin/does-not-exist
out=$(dump_wedge_state 2>&1)
if grep -q 'py-spy: .* absent' <<<"$out" && grep -q 'Threads:' <<<"$out"; then
    ok "missing py-spy degrades to kernel-only with an explicit line"
else
    bad "missing py-spy degrades to kernel-only" "$(grep -i py-spy <<<"$out")"
fi

# 7. a hanging py-spy must be time-boxed: the check is a systemd oneshot, and a
#    dump that outlives its start timeout is killed along with the evidence.
PY_SPY=$TMP/bin/py-spy-hang
start=$(date +%s)
out=$(dump_wedge_state 2>&1)
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -lt 35 ]; then
    ok "a hanging py-spy is time-boxed (returned in ${elapsed}s)"
else
    bad "a hanging py-spy is time-boxed" "took ${elapsed}s"
fi
if grep -q 'wedge diagnostics end' <<<"$out"; then
    ok "the block still terminates after a py-spy timeout"
else
    bad "the block still terminates after a py-spy timeout"
fi

# 8. unresolvable container: no pid, no crash, and it says so
PY_SPY=$TMP/bin/py-spy-stub
unset FAKE_PID
out=$(dump_wedge_state 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'tini UNKNOWN, celery MainProcess UNKNOWN' <<<"$out"; then
    ok "an unresolvable container reports UNKNOWN and does not fail the tick"
else
    bad "an unresolvable container reports UNKNOWN" "rc=$rc $(grep 'wedge diagnostics:' <<<"$out")"
fi

# 9. cmdline without "celery": the fallback still finds the child
kill_trees
start_tree worker
export FAKE_PID=$FAKE_TINI
out=$(dump_wedge_state 2>&1)
if grep -q "celery MainProcess $PY_PID" <<<"$out"; then
    ok "falls back to tini's first child when the cmdline says nothing about celery"
else
    bad "falls back to tini's first child" "$(grep 'wedge diagnostics:' <<<"$out")"
fi

# ==========================================================================
echo
echo "end to end"

# 10. the real binary, against a real Python process. Needs root to ptrace,
#     which is what production has: the idle check runs as root.
REAL_PY_SPY=${REAL_PY_SPY:-}
if [ -z "$REAL_PY_SPY" ]; then
    for c in /usr/local/bin/py-spy "$(command -v py-spy 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { REAL_PY_SPY=$c; break; }
    done
fi
if [ -z "$REAL_PY_SPY" ]; then
    skip "real py-spy names a Python frame" "no py-spy binary; set REAL_PY_SPY="
elif ! sudo -n true 2>/dev/null; then
    skip "real py-spy names a Python frame" "needs root to ptrace"
else
    # Same shape as production: root runs the dump, py-spy attaches to a process
    # it does not own.
    PY_SPY=$TMP/bin/py-spy-root
    printf '#!/bin/bash\nexec sudo -n %s "$@"\n' "$REAL_PY_SPY" > "$PY_SPY"
    chmod +x "$PY_SPY"
    out=$(dump_wedge_state 2>&1)
    if grep -qE 'Thread 0x|Thread [0-9]+ \(' <<<"$out" && grep -q 'time.sleep\|threading' <<<"$out"; then
        ok "real py-spy names Python frames from the wedged process"
    else
        bad "real py-spy names Python frames" "$(grep -A4 'py-spy dump' <<<"$out" | head -6)"
    fi
fi

# ==========================================================================
echo
echo "py-spy supply"

PY_SPY_URL=$(sed -n 's/^PY_SPY_URL="\(.*\)"$/\1/p' "$CLOUD_INIT" | head -1)
PY_SPY_SHA=$(sed -n 's/^PY_SPY_SHA256="\(.*\)"$/\1/p' "$CLOUD_INIT" | head -1)

# 11. transport: this binary is fetched and then run as root.
if [ "${PY_SPY_URL#https://}" != "$PY_SPY_URL" ]; then
    ok "py-spy is fetched over https"
else
    bad "py-spy is fetched over https" "got '$PY_SPY_URL'"
fi

# 12. `curl -JLO` in a boot script takes the output filename from the server and
#     writes it to the current directory. The install must name its own target.
if grep -q 'curl .*-o /usr/local/bin/py-spy.new' "$CLOUD_INIT" && ! grep -q 'curl.*-JLO' "$CLOUD_INIT"; then
    ok "the download names its own output path (no -JLO)"
else
    bad "the download names its own output path"
fi

# 13. PIN DRIFT. The URL is a mutable upload: if its contents are ever replaced,
#     every new worker silently loses py-spy, and nobody finds out until the next
#     wedge produces a kernel-only dump. Network-gated so this stays runnable offline.
if [ -z "$PY_SPY_SHA" ]; then
    bad "the pinned sha256 is present in the script"
elif ! curl -fsS --max-time 20 -o "$TMP/pyspy.dl" "$PY_SPY_URL" 2>/dev/null; then
    skip "the pinned sha256 still matches what the URL serves" "no network or URL unreachable"
else
    got=$(sha256sum "$TMP/pyspy.dl" | cut -d' ' -f1)
    if [ "$got" = "$PY_SPY_SHA" ]; then
        ok "the pinned sha256 still matches what the URL serves"
    else
        bad "the pinned sha256 still matches what the URL serves" \
            "pin $PY_SPY_SHA, served $got -- workers are silently falling back"
    fi
fi

echo
echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ]
