# Lightweight IMAP backup image: mbsync (isync) mirroring remote IMAP -> local Maildir.
# Alpine keeps this in the ~12 MB range while still installing isync from a package
# (no compiling needed). 3.22 ships isync 1.5.1 == upstream latest, which supports
# the modern TLSType / Near / Far config keywords.
FROM alpine:3.22

# isync       -> the `mbsync` binary
# ca-certificates -> CA bundle for IMAPS/STARTTLS validation
# logrotate   -> rotation of the mounted logfile
# tzdata      -> correct local timestamps in logs (drop to save ~3 MB if unwanted)
RUN apk add --no-cache \
        isync \
        ca-certificates \
        logrotate \
        tzdata

COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

# Defaults; override any of these via --env-file / -e at runtime.
ENV BACKUP_DIR=/backups \
    LOG_DIR=/logs \
    SYNC_INTERVAL=1h

# Mount host directories over these for persistent backups + logs.
VOLUME ["/backups", "/logs"]

WORKDIR /app
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["backup"]
