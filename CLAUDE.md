# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A containerized wrapper around `mbsync` (isync) that mirrors IMAP accounts (defined via numbered `ACCOUNT_N_*` env vars) into local Maildir trees, and can push those backups back to a new IMAP server (restore/migrate). There is no compiled code — the entire runtime is three POSIX `sh` scripts in `scripts/` on an Alpine base. Podman-first (rootless, SELinux `:Z`, Quadlet unit), but Docker/Compose is supported.

## Commands

```sh
podman build --format docker -t imap-backup .   # build (Containerfile, not Dockerfile);
                                                # --format docker keeps HEALTHCHECK (OCI drops it)

# Smoke-test a single backup cycle (needs a real .env; cp .env.example .env):
podman run --rm --userns=keep-id --env-file .env \
  -v ./backups:/backups:Z -v ./logs:/logs:Z imap-backup sync-once

# Lint the shell scripts (POSIX sh — no bashisms):
shellcheck -s sh scripts/*.sh
```

There is no test suite. Verifying script changes means building the image and running `sync-once` (or `restore`) against a real account. To inspect the generated mbsync config without hitting a server: `podman run --rm --env-file .env --entrypoint sh imap-backup -c '. scripts/lib.sh && gen_backup_config'`.

## Architecture

Container entry modes (`scripts/entrypoint.sh` CMD): `backup` (default, infinite loop with `SYNC_INTERVAL` sleep and SIGTERM-graceful shutdown), `sync-once` (single cycle), `restore [INDEX ...]` (delegates to `restore.sh`).

`scripts/lib.sh` is the core, sourced by both other scripts. It:
- Enumerates accounts by scanning the environment for `ACCOUNT_N_USER` (indices need not be contiguous).
- Generates the mbsync config **at runtime into /tmp** — there is no static mbsyncrc. `gen_backup_config` (remote=Far → Maildir=Near, Pull) and `gen_restore_config` (Maildir=Near → new remote=Far, Push) are the two generators; `RETAIN_DELETED` toggles mirror vs. archival Sync/Expunge lines.
- Deliberately avoids `set -e`: one failing account/cycle must not kill the long-running loop. All output goes to stdout *and* is tee'd to `$LOG_FILE` (`log`, `run_logged`); logrotate runs in-process after each cycle.

Sync-state separation is a core design invariant: backup state lives inside each mailbox (`SyncState *` → `.mbsyncstate` per folder, so `/backups` is self-contained and portable), while restore state lives in `/backups/.mbsync-restore-state/<account>/` so a restore never disturbs the backup baseline. Don't merge these.

Health checks: the backup loop hands state to `scripts/healthcheck.sh` via `/tmp/imap-backup.health` (`running|ok|error <epoch> <consecutive-failures>`, written atomically) — unhealthy when stale past `SYNC_INTERVAL + HEALTH_GRACE` or after `HEALTH_MAX_FAILURES` consecutive failed cycles; one-off modes never write the file and always report healthy. The check is deliberately declared in three places (Containerfile `HEALTHCHECK`, Compose `healthcheck:`, Quadlet `HealthCmd=`) because OCI-format images drop the instruction — keep them in sync.

User-supplied values are defended at two points: `sanitize_name` (folder names — strips `/`) and `mbsync_quote` (values embedded in the generated config). Route any new user-controlled string through these.

## CI / publishing

`.github/workflows/publish.yml` builds multi-arch (amd64+arm64) and pushes to GHCR and Docker Hub on every main push, tag, and a weekly schedule (picks up new Alpine/isync). A Trivy scan of the amd64 image gates the push — HIGH/CRITICAL fixable CVEs fail the build. Tags include `latest`, `isync-<version>` (detected from Alpine at build time), `sha-<short>`, and `YYYYMMDD` on scheduled runs.

Gotchas:
- The workflow's `paths-ignore` skips rebuilds for docs/compose/quadlet changes — but `DOCKERHUB.md` must **not** be added to it, since a publish run syncs that file to the Docker Hub description.
- Because `paths-ignore` also applies to tag pushes, cut release tags on a commit that includes a code change, or use `workflow_dispatch`.
- Docker Hub steps are conditional on secrets existing, so the job stays green in forks; the description sync needs `DOCKERHUB_PASSWORD` (account password — the API rejects PATs) and is `continue-on-error`.

## Conventions

- Scripts are POSIX `sh` (BusyBox ash), not bash — no arrays, no `[[`, no `local` assumptions beyond what's already used. `SYNC_INTERVAL` relies on BusyBox `sleep` accepting `30m`/`1h` suffixes.
- README.md and DOCKERHUB.md cover the same material for different audiences (repo vs. Docker Hub page); keep user-facing changes in sync across both, plus `.env.example` for any new config variable.
