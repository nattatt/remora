#!/bin/bash
# /opt/remora/launcher.sh
#
# Runs INSIDE oniux's network namespace as the entry point for the
# combined xmrig + watcher service.  oniux execs this script, which
# spawns xmrig (background) and the watcher (background sibling).
#
# Watcher lives or dies on its own — we just respawn it locally if it
# crashes.  Only xmrig's death triggers full-service restart by
# supervise-daemon, because xmrig is the actual workload.

set -e

XMRIG_PID=

cleanup() {
    trap - TERM INT EXIT
    [ -n "$XMRIG_PID" ] && kill -TERM "$XMRIG_PID" 2>/dev/null || true
    sleep 3
    [ -n "$XMRIG_PID" ] && kill -KILL "$XMRIG_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# Launch xmrig in background — it's the workload.
/opt/remora/bin/xmrig --config /opt/remora/xmrig.json &
XMRIG_PID=$!

# Watcher in its own retry loop so transient failures don't bring
# down xmrig.  Runs only as long as xmrig is alive.  Stdout/stderr go
# to watcher.log; xmrig writes to xmrig.log directly via its `log-file`
# config setting (relying on stdio inheritance through oniux is
# unreliable — xmrig goes silent when stdout isn't a tty).
(
    while kill -0 "$XMRIG_PID" 2>/dev/null; do
        /opt/remora/scale-watcher.sh || true
        sleep 5
    done
) >> /opt/remora/watcher.log 2>&1 &

# Wait specifically for xmrig — only its exit causes us to exit.
wait "$XMRIG_PID"
