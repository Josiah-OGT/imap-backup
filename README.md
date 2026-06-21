# imap-backup

[![build-and-publish](https://github.com/Josiah-OGT/imap-backup/actions/workflows/publish.yml/badge.svg)](https://github.com/Josiah-OGT/imap-backup/actions/workflows/publish.yml)

Containerized [`mbsync`](https://isync.sourceforge.io/) (isync) that mirrors a
list of IMAP accounts — defined in a `.env` file — into local **Maildir**
backups, and can **restore** those backups to a new IMAP server.

- **Lightweight:** Alpine + isync, ~20 MB image.
- **Backup:** long-running container, one sync cycle every `SYNC_INTERVAL`.
- **Files on disk:** one message = one file under `<backup>/<account>/`, restorable and greppable.
- **Restore/migrate:** push a Maildir back up to a new server, with an optional pre-restore freshening sync.
- **Logging:** live to `podman logs` *and* a mounted logfile with `logrotate`.
- **Podman-first:** rootless, SELinux-aware, Quadlet service unit included.

## Container images

Published multi-arch (`amd64` + `arm64`) to both registries on every push and
weekly (the weekly rebuild picks up new isync / Alpine releases automatically):

```sh
podman pull ghcr.io/josiah-ogt/imap-backup:latest
# or
podman pull docker.io/<dockerhub-namespace>/imap-backup:latest
```

Tags: `latest`, `isync-<version>` (e.g. `isync-1.5.1`), `sha-<short>`, and a
`YYYYMMDD` date tag on the weekly build. Pin `isync-<version>` or a date tag for
reproducibility; use `latest` to always get the freshest isync.

## How it works

```
BACKUP   remote IMAP  --(mbsync Pull)-->  /backups/<account>/  (Maildir)
RESTORE  /backups/<account>/  --(mbsync Push)-->  NEW IMAP server
```

Each account becomes one Maildir tree, e.g. `/backups/alice@gmail.com/INBOX/...`.
The address is used verbatim as the folder name (valid on Linux; quoted in the
generated config). Override with `ACCOUNT_N_NAME` if you prefer.

## 1. Configure

```sh
cp .env.example .env
$EDITOR .env          # add your accounts + credentials
```

Accounts are numbered blocks; indices need not be contiguous. See `.env.example`
for the full field reference. Minimum per account:

```sh
ACCOUNT_1_HOST=imap.gmail.com
ACCOUNT_1_USER=alice@gmail.com
ACCOUNT_1_PASS=app-password-here
```

> For Gmail/Outlook you'll generally need an **app password**, not your login
> password. To avoid plaintext in `.env`, use `ACCOUNT_N_PASSCMD` instead
> (any command that prints the password, e.g. `pass show alice`).

## 2. Build

```sh
podman build -t imap-backup .
```

## 3. Run (long-running backup)

```sh
mkdir -p backups logs
podman run -d --name imap-backup \
  --userns=keep-id \
  --env-file .env \
  -v ./backups:/backups:Z \
  -v ./logs:/logs:Z \
  imap-backup
```

- `--userns=keep-id` — rootless mapping so backup files are owned by **you** on the host.
- `:Z` — SELinux relabel for the bind mounts (required on Fedora).

Watch it:

```sh
podman logs -f imap-backup     # live; also written to ./logs/imap-backup.log
```

Run a single cycle instead of the loop (handy for a first test):

```sh
podman run --rm --userns=keep-id --env-file .env \
  -v ./backups:/backups:Z -v ./logs:/logs:Z \
  imap-backup sync-once
```

## Run with Docker / Docker Compose

Prefer Docker? A [`docker-compose.yml`](docker-compose.yml) is included. After
configuring `.env` (step 1 above):

```sh
mkdir -p backups logs
docker compose up -d
```

This pulls the published image and runs the same long-running backup service.
Watch it:

```sh
docker compose logs -f      # live; also written to ./logs/imap-backup.log
```

One-off commands — the running backup service is left untouched:

```sh
docker compose run --rm imap-backup sync-once     # a single backup cycle
docker compose run --rm imap-backup restore       # restore all accounts
docker compose run --rm imap-backup restore 1 3   # restore specific indices
```

Stop / update:

```sh
docker compose down                 # stop & remove the container
docker compose pull && docker compose up -d   # update to the latest image
```

> **File ownership:** under rootful Docker the container runs as root, so backup
> files land on the host owned by `root`. To own them as yourself, uncomment the
> `user:` line in `docker-compose.yml` and start with
> `PUID=$(id -u) PGID=$(id -g) docker compose up -d`. (Podman's `--userns=keep-id`
> handles this automatically — see below.) The `:Z` volume suffix relabels mounts
> for SELinux on Fedora/RHEL; drop it on non-SELinux hosts.

Without Compose, the equivalent `docker run`:

```sh
docker run -d --name imap-backup --env-file .env \
  -v ./backups:/backups:Z -v ./logs:/logs:Z \
  ghcr.io/josiah-ogt/imap-backup:latest
```

## 4. Run as a service (Quadlet + systemd)

For "always running, survives reboot" on Fedora, use the included Quadlet unit
(`quadlet/imap-backup.container`). It runs the same long-running container as a
user service with `Restart=always`:

```sh
mkdir -p ~/.config/containers/systemd ~/.config/imap-backup
cp quadlet/imap-backup.container ~/.config/containers/systemd/
cp .env ~/.config/imap-backup/.env
# edit the Volume/EnvironmentFile paths in the unit if needed
systemctl --user daemon-reload
systemctl --user start imap-backup.service
loginctl enable-linger "$USER"     # keep running after logout / across reboot
journalctl --user -u imap-backup -f
```

## 5. Restore / migrate to a new server

Set the restore target for each account in `.env` (omit to fall back to the
original source host/credentials):

```sh
ACCOUNT_1_RESTORE_HOST=imap.newserver.com
ACCOUNT_1_RESTORE_USER=alice@newserver.com
ACCOUNT_1_RESTORE_PASS=new-password
# optional: RESTORE_PRESYNC=true  -> pull latest from source before pushing
```

Then run a one-off restore container (the backup service is untouched):

```sh
# all accounts:
podman run --rm --userns=keep-id --env-file .env \
  -v ./backups:/backups:Z -v ./logs:/logs:Z \
  imap-backup restore

# or specific account indices (pass them after `restore`):
podman run --rm --userns=keep-id --env-file .env \
  -v ./backups:/backups:Z -v ./logs:/logs:Z \
  imap-backup restore 1 3
```

Restore flow per account: *(optional)* freshening pull from the source → push
Maildir to the target. Restore sync-state is kept separately under
`/backups/.mbsync-restore-state/` so it never disturbs the backup baseline; to
restore the same mailbox to a *different* fresh server later, clear that
directory for the account first.

## Configuration reference

| Variable | Default | Meaning |
|----------|---------|---------|
| `SYNC_INTERVAL` | `1h` | Time between cycles (`30`, `30m`, `1h`, `1d`). |
| `RETAIN_DELETED` | `true` | `true` archival (keep server-deleted mail); `false` exact mirror. |
| `RESTORE_PRESYNC` | `false` | Pull latest from source before a restore. |
| `LOG_DIR` | `/logs` | Logfile directory (mount it). |
| `LOG_MAX_SIZE` | `10M` | Rotate after this size. |
| `LOG_KEEP` | `7` | Rotated logs retained. |
| `LOG_TIMESTAMPS` | `true` | ISO timestamps on log lines. |
| `LOG_COMPRESS` | `false` | gzip rotated logs. |
| `BACKUP_DIR` | `/backups` | Maildir root (mount it). |
| `ACCOUNT_N_HOST` / `_USER` / `_PASS` | — | Required per account. |
| `ACCOUNT_N_PORT` / `_TLS` / `_NAME` / `_PASSCMD` | `993` / `IMAPS` / address / — | Optional. |
| `ACCOUNT_N_RESTORE_HOST/_PORT/_USER/_PASS/_TLS/_PASSCMD` | source values | Restore target. |

## Notes & caveats

- **Stopping:** `podman stop` sends SIGTERM; the container finishes the
  in-progress account, then exits (Podman force-kills after its stop timeout).
- **First backup of a large mailbox** can take a while; subsequent cycles are incremental.
- **Restore duplicates:** re-running a restore is resume-safe thanks to the
  persisted restore sync-state. Pointing the same account at a brand-new server
  requires clearing that account's state dir (see above).
- **TLS:** defaults to IMAPS (993) with the system CA bundle. Use
  `ACCOUNT_N_TLS=STARTTLS` (+ `ACCOUNT_N_PORT=143`) for STARTTLS servers.
