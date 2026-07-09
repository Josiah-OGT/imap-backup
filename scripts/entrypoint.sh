#!/bin/sh
# imap-backup entrypoint.
#   backup     (default) long-running loop: sync all accounts every SYNC_INTERVAL
#   sync-once  run a single backup cycle and exit
#   restore    delegate to restore.sh (push Maildir -> new server)
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

MBSYNCRC=/tmp/mbsyncrc
LOGROTATE_CONF=/tmp/logrotate.conf
LOGROTATE_STATE="${LOG_DIR}/.logrotate.state"

# Build the logrotate config from runtime env values.
generate_logrotate_conf() {
    _compress=""
    if [ "$LOG_COMPRESS" = "true" ]; then
        _compress="    compress
    delaycompress"
    fi
    cat > "$LOGROTATE_CONF" <<EOF
"${LOG_FILE}" {
    copytruncate
    rotate ${LOG_KEEP}
    size ${LOG_MAX_SIZE}
    missingok
    notifempty
${_compress}
}
EOF
}

rotate_logs() {
    [ -f "$LOG_FILE" ] || return 0
    logrotate -s "$LOGROTATE_STATE" "$LOGROTATE_CONF" 2>/dev/null \
        || log "WARNING: logrotate pass failed"
}

run_backup_cycle() {
    gen_backup_config > "$MBSYNCRC"
    if [ ! -s "$MBSYNCRC" ]; then
        log "ERROR: no accounts configured (set ACCOUNT_1_HOST/USER/PASS ...)"
        return 1
    fi
    log "=== sync cycle start ==="
    _cycle_rc=0
    if run_logged mbsync $(mbsync_verbosity) -c "$MBSYNCRC" -a; then
        log "=== sync cycle complete ==="
    else
        _cycle_rc=$?
        log "=== sync cycle finished WITH ERRORS (mbsync exit ${_cycle_rc}) ==="
    fi
    rotate_logs
    return "$_cycle_rc"
}

cmd="${1:-backup}"
[ $# -gt 0 ] && shift

# Greet on every launch (backup, sync-once, or restore).
case "$cmd" in backup|sync-once|restore) banner ;; esac

case "$cmd" in
    backup)
        generate_logrotate_conf
        log "imap-backup starting (interval=${SYNC_INTERVAL}, log_level=${LOG_LEVEL}, accounts=[$(account_indices | tr '\n' ' ')])"

        TERM_FLAG=0
        trap 'TERM_FLAG=1; log "shutdown signal received; stopping after current cycle"' TERM INT

        # Track consecutive cycle failures and hand loop state to healthcheck.sh.
        FAIL_COUNT=0
        while [ "$TERM_FLAG" -eq 0 ]; do
            health_write running "$FAIL_COUNT"
            if run_backup_cycle; then
                FAIL_COUNT=0
                health_write ok
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                health_write error "$FAIL_COUNT"
            fi
            [ "$TERM_FLAG" -eq 0 ] || break

            log "sleeping ${SYNC_INTERVAL} until next cycle"
            # Background the sleep so an incoming signal interrupts wait promptly.
            sleep "$SYNC_INTERVAL" &
            _sleep_pid=$!
            wait "$_sleep_pid" 2>/dev/null || true
            kill "$_sleep_pid" 2>/dev/null || true
        done

        log "imap-backup stopped"
        ;;

    sync-once)
        generate_logrotate_conf
        run_backup_cycle
        ;;

    restore)
        exec "${SCRIPT_DIR}/restore.sh" "$@"
        ;;

    *)
        echo "Usage: entrypoint.sh {backup|sync-once|restore [INDEX ...]}" >&2
        exit 1
        ;;
esac
