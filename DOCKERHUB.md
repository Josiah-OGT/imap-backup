# imap-backup

Containerized [`mbsync`](https://isync.sourceforge.io/) (isync) that mirrors a
list of IMAP accounts — defined in a `.env` file — into local **Maildir**
backups, and can **restore** those backups to a new IMAP server.

- **Lightweight:** Alpine + isync, ~20 MB image, multi-arch (`amd64` + `arm64`).
- **Backup:** long-running container, one sync cycle every `SYNC_INTERVAL`.
- **Files on disk:** one message = one file under `<backup>/<account>/`, restorable and greppable.
- **Restore/migrate:** push a Maildir back up to a new server.
- **Scanned:** every published image passes a Trivy CVE gate (fails on fixable HIGH/CRITICAL); rebuilt weekly for upstream patches.

📖 **Full documentation & source:** https://github.com/Josiah-OGT/imap-backup

## Tags

`latest`, `vX.Y.Z` (releases), `isync-<version>` (e.g. `isync-1.5.1`),
`sha-<short>`, and a `YYYYMMDD` date tag on the weekly build. Pin a `vX.Y.Z` or
`isync-<version>` tag for reproducibility; use `latest` for the freshest isync.

```sh
docker pull unsalted1832/imap-backup:latest
```

## Quick start (Docker Compose)

**1. Create `docker-compose.yml`:**

```yaml
services:
  imap-backup:
    image: unsalted1832/imap-backup:latest
    container_name: imap-backup
    env_file: .env
    restart: unless-stopped
    volumes:
      - ./backups:/backups
      - ./logs:/logs
```

**2. Create `.env`** with your accounts (numbered blocks; gaps are fine):

```sh
# Global (all optional — defaults shown)
SYNC_INTERVAL=1h
RETAIN_DELETED=false        # false = exact mirror; true = keep server-deleted mail
LOG_LEVEL=normal            # normal | verbose | debug

# Account 1 (minimum: HOST, USER, PASS)
ACCOUNT_1_HOST=imap.gmail.com
ACCOUNT_1_USER=alice@gmail.com
ACCOUNT_1_PASS=app-password-here
# ACCOUNT_1_PORT=993        # optional (default 993)
# ACCOUNT_1_TLS=IMAPS       # IMAPS (default) or STARTTLS (+ PORT=143)
```

> For Gmail/Outlook use an **app password**, not your login password. To avoid
> plaintext, use `ACCOUNT_N_PASSCMD` (any command that prints the password).

**3. Start the backup service:**

```sh
mkdir -p backups logs
docker compose up -d
docker compose logs -f      # live; also written to ./logs/imap-backup.log
```

## One-off commands

The running backup service is left untouched:

```sh
docker compose run --rm imap-backup sync-once     # a single backup cycle
docker compose run --rm imap-backup restore       # restore all accounts
docker compose run --rm imap-backup restore 1 3   # restore specific indices
```

## Stop / update

```sh
docker compose down                            # stop & remove the container
docker compose pull && docker compose up -d    # update to the latest image
```

## Without Compose (`docker run`)

```sh
docker run -d --name imap-backup --env-file .env \
  -v ./backups:/backups -v ./logs:/logs \
  unsalted1832/imap-backup:latest
```

Run a single cycle instead of the loop:

```sh
docker run --rm --env-file .env \
  -v ./backups:/backups -v ./logs:/logs \
  unsalted1832/imap-backup:latest sync-once
```

## Restore / migrate to a new server

Set the restore target per account in `.env` (omit any field to fall back to the
original source value):

```sh
ACCOUNT_1_RESTORE_HOST=imap.newserver.com
ACCOUNT_1_RESTORE_USER=alice@newserver.com
ACCOUNT_1_RESTORE_PASS=new-password
# optional: RESTORE_PRESYNC=true   -> pull latest from source before pushing
```

Then run a one-off restore (`restore` pushes the local Maildir to the target):

```sh
docker compose run --rm imap-backup restore        # all accounts
docker compose run --rm imap-backup restore 1      # specific account(s)
```

## Configuration reference

| Variable | Default | Meaning |
|----------|---------|---------|
| `SYNC_INTERVAL` | `1h` | Time between cycles (`30`, `30m`, `1h`, `1d`). |
| `RETAIN_DELETED` | `false` | `false` exact mirror (propagate server deletions); `true` archival (keep server-deleted mail). |
| `RESTORE_PRESYNC` | `false` | Pull latest from source before a restore. |
| `LOG_LEVEL` | `normal` | mbsync verbosity: `normal` (summary), `verbose` (`-V`), `debug` (`-V -D`). |
| `LOG_DIR` | `/logs` | Logfile directory (mount it). |
| `LOG_MAX_SIZE` | `10M` | Rotate after this size. |
| `LOG_KEEP` | `7` | Rotated logs retained. |
| `LOG_TIMESTAMPS` | `true` | ISO timestamps on log lines. |
| `LOG_COMPRESS` | `false` | gzip rotated logs. |
| `BACKUP_DIR` | `/backups` | Maildir root (mount it). |
| `ACCOUNT_N_HOST` / `_USER` / `_PASS` | — | Required per account. |
| `ACCOUNT_N_PORT` / `_TLS` / `_NAME` / `_PASSCMD` | `993` / `IMAPS` / address / — | Optional. |
| `ACCOUNT_N_RESTORE_HOST/_PORT/_USER/_PASS/_TLS/_PASSCMD` | source values | Restore target. |

## Notes

- **File ownership:** under rootful Docker the container runs as root, so backup
  files are owned by `root`. To own them as yourself, run as your UID/GID:
  `docker compose run --user "$(id -u):$(id -g)" ...` (pre-create `backups/` and
  `logs/` first).
- **SELinux (Fedora/RHEL):** append `:Z` to the volume mounts, e.g.
  `./backups:/backups:Z`.
- **Stopping:** `docker stop` sends SIGTERM; the container finishes the
  in-progress account, then exits.
- **TLS:** defaults to IMAPS (993) with the system CA bundle. Use
  `ACCOUNT_N_TLS=STARTTLS` (+ `ACCOUNT_N_PORT=143`) for STARTTLS servers.

---

Licensed under the terms in the [repository](https://github.com/Josiah-OGT/imap-backup).
