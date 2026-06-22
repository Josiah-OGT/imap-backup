#!/bin/sh
# Shared helpers for imap-backup: config defaults, account enumeration,
# .mbsyncrc generation, and logging. Sourced by entrypoint.sh and restore.sh.
#
# NOTE: this file intentionally does NOT enable `set -e`; the backup loop must
# survive a single account/cycle failure without taking down the container.

# ---- Defaults (override via .env / -e) ----------------------------------------
: "${BACKUP_DIR:=/backups}"
: "${LOG_DIR:=/logs}"
: "${LOG_FILE:=${LOG_DIR}/imap-backup.log}"
: "${LOG_MAX_SIZE:=10M}"        # rotate when the logfile exceeds this size
: "${LOG_KEEP:=7}"              # how many rotated logs to retain
: "${LOG_TIMESTAMPS:=true}"     # prefix log lines with an ISO timestamp
: "${LOG_COMPRESS:=false}"      # gzip rotated logs (needs gzip; off by default)
: "${LOG_LEVEL:=normal}"        # mbsync verbosity: normal | verbose | debug
: "${SYNC_INTERVAL:=1h}"        # BusyBox sleep arg: accepts 30, 30m, 1h, 2d ...
: "${RETAIN_DELETED:=false}"    # false = exact mirror (propagate server deletions)
                                # true  = archival (keep mail deleted on the server)
: "${RESTORE_PRESYNC:=false}"   # true = freshen from source before restoring

CA_FILE=/etc/ssl/certs/ca-certificates.crt
# Restore sync-state lives OUTSIDE the per-folder .mbsyncstate used by backups,
# so a restore never disturbs the backup baseline. Persisted for retry safety.
RESTORE_STATE_DIR="${BACKUP_DIR}/.mbsync-restore-state"

# ---- Logging ------------------------------------------------------------------
# ASCII banner shown once at container launch (and tee'd to the logfile, so the
# start of each run is easy to spot). Single-quoted heredoc => printed verbatim.
banner() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    cat <<'BANNER' | tee -a "$LOG_FILE"

  _                          _                _
 (_)_ __ ___   __ _ _ __    | |__   __ _  ___| | ___   _ _ __
 | | '_ ` _ \ / _` | '_ \   | '_ \ / _` |/ __| |/ / | | | '_ \
 | | | | | | | (_| | |_) |  | |_) | (_| | (__|   <| |_| | |_) |
 |_|_| |_| |_|\__,_| .__/   |_.__/ \__,_|\___|_|\_\\__,_| .__/
                   |_|        mbsync IMAP backup        |_|

BANNER
}

# Everything goes to stdout (for `podman logs`) AND is tee'd to the logfile.
log() {
    _msg="$*"
    if [ "${LOG_TIMESTAMPS}" = "true" ]; then
        _msg="$(date '+%Y-%m-%dT%H:%M:%S%z') ${_msg}"
    fi
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$_msg" | tee -a "$LOG_FILE"
}

# mbsync verbosity flags for the current LOG_LEVEL. Echoed unquoted at the call
# site so they word-split into separate args:
#   normal  -> (nothing)  just the summary counters
#   verbose -> -V         per-mailbox / per-message progress
#   debug   -> -V -D      everything above plus mbsync debug output
mbsync_verbosity() {
    case "$LOG_LEVEL" in
        verbose) printf '%s' '-V' ;;
        debug)   printf '%s' '-V -D' ;;
        normal)  : ;;
        *) log "WARNING: unknown LOG_LEVEL '${LOG_LEVEL}', using normal" >&2 ;;
    esac
}

# Run a command with combined stdout+stderr tee'd to the logfile, returning the
# command's exit status (not tee's) so callers can detect mbsync failures.
run_logged() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    ( set -o pipefail 2>/dev/null; "$@" 2>&1 | tee -a "$LOG_FILE" )
}

# ---- Small utilities ----------------------------------------------------------
# Read an env var whose name is computed at runtime, e.g. getvar "ACCOUNT_1_USER".
getvar() {
    eval "printf '%s' \"\${$1:-}\""
}

# Make a value safe to embed inside an mbsync double-quoted string.
mbsync_quote() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Guard a user-supplied folder name: trim whitespace and neutralise any '/'
# (the only character illegal in a Linux path component) to prevent escaping
# the backup root. '@' '.' '+' '-' are all valid and kept verbatim.
sanitize_name() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's#^[[:space:]]*##; s#[[:space:]]*$##; s#/#_#g'
}

# Print the sorted, unique account indices defined in the environment
# (every N for which ACCOUNT_N_USER is set). Gaps are fine.
account_indices() {
    env | sed -n 's/^ACCOUNT_\([0-9][0-9]*\)_USER=.*/\1/p' | sort -n -u
}

# On-disk Maildir folder name for an account: ACCOUNT_N_NAME if set,
# otherwise the literal address (sanitised).
account_name() {
    _idx="$1"
    _nm="$(getvar "ACCOUNT_${_idx}_NAME")"
    [ -n "$_nm" ] || _nm="$(getvar "ACCOUNT_${_idx}_USER")"
    sanitize_name "$_nm"
}

# ---- .mbsyncrc generation -----------------------------------------------------
# Backup direction: remote (Far) -> local Maildir (Near). Args: optional indices.
gen_backup_config() {
    _indices="$*"
    [ -n "$_indices" ] || _indices="$(account_indices)"
    for _idx in $_indices; do
        _host="$(getvar "ACCOUNT_${_idx}_HOST")"
        _port="$(getvar "ACCOUNT_${_idx}_PORT")";   [ -n "$_port" ] || _port=993
        _user="$(getvar "ACCOUNT_${_idx}_USER")"
        _pass="$(getvar "ACCOUNT_${_idx}_PASS")"
        _passcmd="$(getvar "ACCOUNT_${_idx}_PASSCMD")"
        _tls="$(getvar "ACCOUNT_${_idx}_TLS")";     [ -n "$_tls" ] || _tls=IMAPS
        _name="$(account_name "$_idx")"
        _maildir="${BACKUP_DIR}/${_name}"

        if [ -z "$_host" ] || [ -z "$_user" ]; then
            log "WARNING: account ${_idx} missing HOST or USER; skipping" >&2
            continue
        fi
        mkdir -p "$_maildir"

        # Archival keeps server-deleted mail locally; mirror propagates deletes.
        if [ "$RETAIN_DELETED" = "true" ]; then
            _sync="Sync Pull New Upgrade Flags"
            _remove="Remove None"
            _expunge="Expunge None"
        else
            _sync="Sync Pull"
            _remove="Remove Near"
            _expunge="Expunge Near"
        fi

        if [ -n "$_passcmd" ]; then
            _passline="PassCmd \"$(mbsync_quote "$_passcmd")\""
        else
            _passline="Pass \"$(mbsync_quote "$_pass")\""
        fi

        cat <<EOF
IMAPAccount acct${_idx}
Host ${_host}
Port ${_port}
User "$(mbsync_quote "$_user")"
${_passline}
TLSType ${_tls}
CertificateFile ${CA_FILE}

IMAPStore acct${_idx}-remote
Account acct${_idx}

MaildirStore acct${_idx}-local
Path "${_maildir}/"
Inbox "${_maildir}/INBOX"
SubFolders Verbatim

Channel acct${_idx}
Far :acct${_idx}-remote:
Near :acct${_idx}-local:
Patterns *
Create Near
${_remove}
${_expunge}
${_sync}
SyncState *

EOF
    done
}

# Restore direction: local Maildir (Near) -> NEW remote (Far). Per-account
# RESTORE_* overrides fall back to the original source settings if unset.
gen_restore_config() {
    _indices="$*"
    [ -n "$_indices" ] || _indices="$(account_indices)"
    for _idx in $_indices; do
        _name="$(account_name "$_idx")"
        _maildir="${BACKUP_DIR}/${_name}"

        _host="$(getvar "ACCOUNT_${_idx}_RESTORE_HOST")"
        [ -n "$_host" ] || _host="$(getvar "ACCOUNT_${_idx}_HOST")"
        _port="$(getvar "ACCOUNT_${_idx}_RESTORE_PORT")"
        [ -n "$_port" ] || _port="$(getvar "ACCOUNT_${_idx}_PORT")"
        [ -n "$_port" ] || _port=993
        _user="$(getvar "ACCOUNT_${_idx}_RESTORE_USER")"
        [ -n "$_user" ] || _user="$(getvar "ACCOUNT_${_idx}_USER")"
        _pass="$(getvar "ACCOUNT_${_idx}_RESTORE_PASS")"
        [ -n "$_pass" ] || _pass="$(getvar "ACCOUNT_${_idx}_PASS")"
        _passcmd="$(getvar "ACCOUNT_${_idx}_RESTORE_PASSCMD")"
        _tls="$(getvar "ACCOUNT_${_idx}_RESTORE_TLS")"
        [ -n "$_tls" ] || _tls="$(getvar "ACCOUNT_${_idx}_TLS")"
        [ -n "$_tls" ] || _tls=IMAPS

        _statedir="${RESTORE_STATE_DIR}/${_name}"
        mkdir -p "$_statedir"

        if [ -z "$_host" ] || [ -z "$_user" ]; then
            log "WARNING: account ${_idx} has no restore target; skipping" >&2
            continue
        fi

        if [ -n "$_passcmd" ]; then
            _passline="PassCmd \"$(mbsync_quote "$_passcmd")\""
        else
            _passline="Pass \"$(mbsync_quote "$_pass")\""
        fi

        cat <<EOF
IMAPAccount acct${_idx}-restore
Host ${_host}
Port ${_port}
User "$(mbsync_quote "$_user")"
${_passline}
TLSType ${_tls}
CertificateFile ${CA_FILE}

IMAPStore acct${_idx}-restore-remote
Account acct${_idx}-restore

MaildirStore acct${_idx}-restore-local
Path "${_maildir}/"
Inbox "${_maildir}/INBOX"
SubFolders Verbatim

Channel acct${_idx}-restore
Far :acct${_idx}-restore-remote:
Near :acct${_idx}-restore-local:
Patterns *
Create Far
Remove None
Expunge None
Sync Push New Upgrade Flags
SyncState ${_statedir}/

EOF
    done
}
