# imap-backup

[![build-and-publish](https://github.com/Josiah-OGT/imap-backup/actions/workflows/publish.yml/badge.svg)](https://github.com/Josiah-OGT/imap-backup/actions/workflows/publish.yml)
[![latest release](https://img.shields.io/github/v/release/Josiah-OGT/imap-backup?label=release)](https://github.com/Josiah-OGT/imap-backup/releases/latest)

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

## Security & vulnerability scanning

Every automated build is **scanned for CVEs before it is published** — a
vulnerable image never reaches the registries. The
[`build-and-publish`](.github/workflows/publish.yml) workflow:

1. Builds a single-arch (`amd64`) image into the CI runner.
2. Scans it with [Trivy](https://github.com/aquasecurity/trivy), failing the run
   on any **HIGH/CRITICAL** vulnerability that has a fix available
   (`--ignore-unfixed`, so unpatchable advisories don't block releases).
3. Only on a clean scan does it build and push the multi-arch image.

OS-package CVEs are architecture-independent, so the `amd64` scan represents the
`arm64` image too. Several layers keep the published image current:

- **`apk upgrade` at build time** — the `Containerfile` upgrades the base
  image's pre-installed packages (e.g. OpenSSL), so patches already released by
  Alpine are pulled in even when no direct dependency requires them.
- **Weekly rebuild** — a scheduled run rebuilds from the latest Alpine + isync
  packages, so fixes land without a code change (and are re-scanned by the gate).
- **Dependabot** keeps the GitHub Actions and base image current.

Scan any tag yourself:

```sh
podman run --rm aquasec/trivy image ghcr.io/josiah-ogt/imap-backup:latest
```

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

Prefer Docker? The image is published, so you only need two files —
[`docker-compose.yml`](docker-compose.yml) and [`.env.example`](.env.example).

**Get the files** — download the two files into an empty directory:

```sh
mkdir imap-backup && cd imap-backup
base=https://raw.githubusercontent.com/Josiah-OGT/imap-backup/main
curl -fsSLO "$base/docker-compose.yml"
curl -fsSL  "$base/.env.example" -o .env.example
```

**Configure** your accounts + credentials:

```sh
cp .env.example .env
$EDITOR .env          # see .env.example for the full field reference
```

**Start** the long-running backup service:

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
Maildir to the target. Restore keeps its own sync-state, separate from the
backup baseline (see [Sync state](#sync-state)); to restore the same mailbox to
a *different* fresh server later, clear that account's restore-state directory
first.

## Sync state

Both directions are **incremental**: mbsync persists where it left off so each
run only transfers what changed. The container itself is stateless — all state
lives on the `/backups` volume, so it survives restarts, upgrades, and even
moving the backup tree to another host.

State is keyed to the server's `UIDVALIDITY` plus per-message **UIDs** and
flags. On each run mbsync reads the recorded UIDs and only acts on newer ones —
that's why a re-run with nothing new reports `+0`. There are two independent
state stores so the two directions never interfere:

| Direction | `SyncState` | Location | Why |
|-----------|-------------|----------|-----|
| **Backup** (server → Maildir) | `*` | `.mbsyncstate` + `.uidvalidity` *inside each mailbox*, e.g. `/backups/<account>/INBOX/.mbsyncstate` | Co-located with the mail, so `/backups` is self-contained — copy it elsewhere and incremental sync still works. |
| **Restore** (Maildir → new server) | explicit dir | `/backups/.mbsync-restore-state/<account>/` | Kept *out* of the mailbox so pushing to a new server never disturbs the backup baseline; makes re-running a restore resume-safe (no duplicate pushes). |

Implications:

- **Resuming** a backup or restore after an interruption is safe — mbsync picks
  up from the last recorded UID.
- **Re-pointing** an account at a genuinely different mailbox, or a server that
  resets its `UIDVALIDITY`, is detected as a mismatch and triggers a full
  re-sync of that mailbox (safe, just slower for one cycle).
- **Restoring the same mailbox to a second fresh server:** clear that account's
  folder under `/backups/.mbsync-restore-state/` first, otherwise mbsync thinks
  those messages are already pushed and skips them.

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
| `LOG_LEVEL` | `normal` | mbsync verbosity: `normal` (summary only), `verbose` (per-mailbox/message progress, `-V`), `debug` (+ mbsync debug output, `-V -D`). |
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
