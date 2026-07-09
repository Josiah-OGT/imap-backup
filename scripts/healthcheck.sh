#!/bin/sh
# Container health check. The backup loop records its state in $HEALTH_FILE
# ("STATE EPOCH FAILS"); this script turns that into a health verdict:
#
#   running          cycle in progress -> healthy (first sync can take hours)
#   ok / error       healthy while fresh; stale (no activity for SYNC_INTERVAL
#                    + HEALTH_GRACE) means the loop died or is stuck
#   error            also unhealthy once HEALTH_MAX_FAILURES consecutive
#                    cycles have failed (bad credentials, unreachable server)
#
# One-off modes (sync-once / restore) never write the file -> always healthy.
# Prints a reason either way; runtimes record it in `inspect`.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

if [ ! -f "$HEALTH_FILE" ]; then
    echo "no backup loop in this container (one-off mode); healthy"
    exit 0
fi

read -r state epoch fails < "$HEALTH_FILE" || { echo "cannot read ${HEALTH_FILE}"; exit 1; }
case "${epoch:-}" in
    ''|*[!0-9]*) echo "malformed ${HEALTH_FILE}: '${state:-} ${epoch:-} ${fails:-}'"; exit 1 ;;
esac

age=$(( $(date +%s) - epoch ))
max_age=$(( $(duration_seconds "$SYNC_INTERVAL" 3600) + $(duration_seconds "$HEALTH_GRACE" 300) ))

case "$state" in
    running)
        echo "sync cycle in progress (started ${age}s ago)"
        exit 0
        ;;
    ok|error)
        if [ "$state" = "error" ] && [ "${fails:-0}" -ge "$HEALTH_MAX_FAILURES" ]; then
            echo "${fails} consecutive failed cycles (limit ${HEALTH_MAX_FAILURES})"
            exit 1
        fi
        if [ "$age" -gt "$max_age" ]; then
            echo "loop stale: no cycle activity for ${age}s (limit ${max_age}s)"
            exit 1
        fi
        echo "last cycle: ${state}, ${age}s ago"
        exit 0
        ;;
    *)
        echo "unknown state '${state}' in ${HEALTH_FILE}"
        exit 1
        ;;
esac
