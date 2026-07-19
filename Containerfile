# Lightweight IMAP backup image: mbsync (isync) mirroring remote IMAP -> local Maildir.
# Alpine keeps this in the ~12 MB range while still installing isync from a package
# (no compiling needed). 3.22 ships isync 1.5.1 == upstream latest, which supports
# the modern TLSType / Near / Far config keywords.
FROM alpine:3.24

# isync       -> the `mbsync` binary
# ca-certificates -> CA bundle for IMAPS/STARTTLS validation
# logrotate   -> rotation of the mounted logfile
# tzdata      -> correct local timestamps in logs (drop to save ~3 MB if unwanted)
# `apk upgrade` first so security patches to packages already baked into the
# base image (e.g. openssl/libssl3 used by mbsync for IMAPS) are picked up — a
# plain `apk add` only installs missing deps and leaves pre-installed ones at
# the base image's (possibly vulnerable) version.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
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

# Healthy while backup cycles keep completing; unhealthy when the loop stalls
# or keeps failing (see scripts/healthcheck.sh). One-off sync-once/restore
# containers always report healthy. NOTE: `podman build` defaults to OCI
# format, which drops HEALTHCHECK — build with `--format docker` to keep it
# (docker-compose.yml and the Quadlet unit define the check either way).
HEALTHCHECK --interval=1m --timeout=10s --start-period=30s --retries=3 \
    CMD /app/scripts/healthcheck.sh
