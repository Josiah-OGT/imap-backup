#!/bin/sh
# Restore / migrate: push backed-up Maildir(s) to a (new) IMAP server.
#
# Flow:
#   1. (optional) RESTORE_PRESYNC=true -> pull latest from the SOURCE server into
#      the Maildir first, so the restore carries the freshest possible data.
#   2. Push the Maildir up to the restore target (ACCOUNT_N_RESTORE_* overrides,
#      falling back to the original source credentials if not set).
#
# Usage: restore.sh [INDEX ...]   (no args = all configured accounts)
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

PRESYNC_RC=/tmp/mbsyncrc-presync
RESTORE_RC=/tmp/mbsyncrc-restore

indices="$*"
[ -n "$indices" ] || indices="$(account_indices)"
if [ -z "$indices" ]; then
    log "ERROR: no accounts found to restore (set ACCOUNT_N_USER ...)"
    exit 1
fi

log "=== RESTORE starting for accounts: $(echo "$indices" | tr '\n' ' ')==="

# --- Step 1: optional pre-restore freshening pull from the source server -------
if [ "$RESTORE_PRESYNC" = "true" ]; then
    log "--- pre-restore sync: pulling latest from SOURCE server(s) ---"
    gen_backup_config $indices > "$PRESYNC_RC"
    for idx in $indices; do
        log "presync account ${idx}"
        run_logged mbsync -c "$PRESYNC_RC" "acct${idx}" \
            || log "WARNING: presync failed for account ${idx} (continuing with existing backup)"
    done
else
    log "--- pre-restore sync disabled (RESTORE_PRESYNC=false) ---"
fi

# --- Step 2: push Maildir(s) to the restore target ----------------------------
log "--- pushing Maildir to target server(s) ---"
gen_restore_config $indices > "$RESTORE_RC"
if [ ! -s "$RESTORE_RC" ]; then
    log "ERROR: no restore targets resolved; nothing to do"
    exit 1
fi

rc=0
for idx in $indices; do
    log "restore account ${idx}"
    if run_logged mbsync -c "$RESTORE_RC" "acct${idx}-restore"; then
        log "restore complete for account ${idx}"
    else
        log "ERROR: restore failed for account ${idx}"
        rc=1
    fi
done

log "=== RESTORE finished (exit ${rc}) ==="
exit "$rc"
