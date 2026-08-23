# azerothcore-backup

Verified, tiered MySQL backups and a restore CLI for dockerized AzerothCore.
It runs as a single sidecar service — no host cron, no bespoke scripts — and
drops into an existing AzerothCore compose stack as one more service block.

## What it is

`azerothcore-backup` is a small, self-contained Docker image built on
`mysql:8.4` (so `mysql`, `mysqldump`, `gzip`, and `gosu` are already present).
It runs a scheduler that takes interval, daily, and monthly `mysqldump`
backups of your AzerothCore databases, verifies every dump before trusting
it, and only marks a backup "complete" once every database in it verified
cleanly. A baked-in `acbackup` CLI handles listing, verification, on-demand
backups, and restore — including an optional auto-restore that can rebuild a
fresh database from the newest good backup when a container starts against
an empty database. Point it at your `ac-database` service, mount a
`/backups` volume, and it runs unattended.

## Quick start

Drop `examples/compose.override.yml` next to your existing AzerothCore
`docker-compose.yml` as `docker-compose.override.yml` (or merge its
`ac-backup` service into an override file you already have):

```yaml
services:
  ac-backup:
    image: uprightbass360/azerothcore-backup:latest
    container_name: ac-backup
    networks: [ac-network]
    environment:
      MYSQL_HOST: ac-database
      MYSQL_PASSWORD: ${DOCKER_DB_ROOT_PASSWORD:-password}
      BACKUP_ALERT_WEBHOOK: ${BACKUP_ALERT_WEBHOOK:-}
    volumes:
      - ${DOCKER_VOL_BACKUPS:-./backups}:/backups
    depends_on:
      ac-database:
        condition: service_healthy
    restart: always
```

Then:

```bash
docker compose up -d
```

Backups appear under the mounted volume (`./backups` by default), organized
into `hourly/`, `daily/`, `monthly/`, and `manual/` subdirectories, each
containing timestamped folders like `20260823_090000/`.

If you'd rather see a complete, minimal stack (MySQL plus the backup
service, no upstream AC compose file required), see
`examples/compose.yml`.

## How backups work

The scheduler (`scripts/backup-scheduler.sh`) runs three tiers from one
loop:

- **Interval (`hourly/`)** — every `BACKUP_INTERVAL_MINUTES` (default `60`).
- **Daily (`daily/`)** — once per day, at or after `BACKUP_DAILY_TIME` (an
  hour, container timezone; default `09`). A date-tracked flag means a slow
  interval backup that happens to span the top of the hour can't cause the
  daily backup to be skipped, and a container restart re-derives the flag
  from what's already on disk instead of skipping or duplicating the day's
  backup.
- **Monthly (`monthly/`)** — the first *complete* daily backup of each
  calendar month is promoted (copied) into `monthly/` once daily backups
  start succeeding for that month.

`manual/` holds on-demand backups from `acbackup now`, plus the automatic
pre-restore safety backups taken before every restore.

Every backup dumps each configured database with `mysqldump
--single-transaction --routines --triggers --events --hex-blob --quick
--lock-tables=false --add-drop-database`, gzips the output, and then
verifies it: the gzip stream must be intact (`gunzip -t`) and the dump must
end with mysqldump's own `Dump completed` trailer, meaning it wasn't cut
short. A `.backup_complete` marker file is written into the backup's
timestamped directory **only if every configured database backed up and
verified successfully** — a partial or failed backup is left without a
marker, so it is honestly reported as incomplete and is never eligible for
restore or promotion to monthly. If any database fails, the alert webhook
fires (see Alerting) and the failure is logged; the backup directory is left
in place, without a marker, for inspection.

Each backup directory also gets a `manifest.json` with:

- `timestamp`, `type` (`interval`/`daily`/`monthly`/`manual`)
- `databases` — every database that was included
- `failed_databases` — any that failed (empty on a complete backup)
- `backup_size` — on-disk size of the directory
- a retention field appropriate to the tier (`retention_hours`,
  `retention_days`, `retention_months`, or `"retention": "manual"`)
- `mysql_version`
- `performance` — `duration_seconds`, `uncompressed_size_mb`,
  `throughput_mb_per_second`

Retention defaults: hourly backups older than `BACKUP_RETENTION_HOURS`
(`6`), daily backups older than `BACKUP_RETENTION_DAYS` (`14`), and monthly
backups older than `BACKUP_RETENTION_MONTHS` (`12`, applied as `months*31`
days) are pruned on every scheduler pass. Manual backups (including
pre-restore safety backups) are never auto-pruned.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `MYSQL_HOST` | `ac-database` | matches the standard AC compose service name |
| `MYSQL_PORT` | `3306` | |
| `MYSQL_USER` | `root` | |
| `MYSQL_PASSWORD` | — | or `MYSQL_PASSWORD_FILE` for secrets |
| `MYSQL_PASSWORD_FILE` | — | path to a file containing the password; takes precedence over `MYSQL_PASSWORD` when the file exists |
| `BACKUP_DATABASES` | `acore_auth acore_world acore_characters` | space/comma separated |
| (auto) | | `acore_playerbots` auto-added when present |
| `BACKUP_INTERVAL_MINUTES` | `60` | |
| `BACKUP_RETENTION_HOURS` | `6` | |
| `BACKUP_RETENTION_DAYS` | `14` | |
| `BACKUP_RETENTION_MONTHS` | `12` | |
| `BACKUP_DAILY_TIME` | `09` | hour, container TZ |
| `BACKUP_ALERT_WEBHOOK` | empty | plain-text POST on failure |
| `AUTO_RESTORE` | `0` | see Restore runbook |
| `AUTO_RESTORE_PROBE` | `acore_auth.account` | `schema.table` probed at startup to decide whether the database is empty |
| `PUID` / `PGID` | `1000` / `1000` | backup file ownership |
| `TZ` | `UTC` | |
| `BACKUP_HEALTHCHECK_MAX_MINUTES` | `120` | freshness window for the container healthcheck; see Alerting |
| `BACKUP_HEALTHCHECK_GRACE_SECONDS` | `4500` | grace period (container uptime, seconds) before freshness is enforced |
| `BACKUP_DIR_BASE` | `/backups` | mount point for the backup volume; only override this if you also change the volume target |

Volume: `/backups` (named volume, bind mount, or NFS — all supported; no
`flock` dependence, tier-root-only chown — see NFS and permissions below).

## Restore runbook

The `acbackup` CLI is baked into the image at `/opt/acbackup/acbackup`
(symlinked to `/usr/local/bin/acbackup`). Run it against a running
container with `docker exec ac-backup acbackup <command>`, or as a one-shot
`docker run ... acbackup <command>` — the entrypoint dispatches straight to
the CLI (via `gosu`, dropping to `PUID:PGID`) whenever the first argument
isn't `scheduler`.

Typical flow before trusting or applying a backup:

```bash
docker exec ac-backup acbackup list
docker exec ac-backup acbackup verify latest
docker exec ac-backup acbackup restore latest
```

- **`acbackup list`** — shows every tier (`hourly`/`daily`/`monthly`/
  `manual`) with each backup's timestamp, complete/incomplete status, and
  size.
- **`acbackup verify <dir|latest>`** — re-checks the completion marker plus
  the gzip integrity and mysqldump completion trailer of every dump in the
  backup. `latest` resolves to the newest *complete* backup across all
  tiers.
- **`acbackup now [--label NAME]`** — takes an on-demand backup into
  `manual/`, named `<label>-<timestamp>` (label defaults to `manual`).
- **`acbackup restore <dir|latest> [--db NAME ...] [--yes]
  [--no-safety-backup]`**:
  - refuses to restore a backup that has no completion marker, or whose
    dumps fail verification — restores only ever come from a backup the CLI
    itself has already validated
  - by default, takes a **pre-restore safety backup** first, into
    `manual/pre-restore-<timestamp>/`, so a bad restore is itself
    recoverable; pass `--no-safety-backup` to skip this (the source backup
    is already verified, so this is a reasonable choice when you're in a
    hurry and short on disk)
  - applies each dump with `mysql`; since every dump carries
    `--add-drop-database`, restoring a database is a clean drop-and-recreate
    of just that database, not a merge
  - asks for interactive confirmation (type `RESTORE`) unless `--yes` is
    given; `--yes` is required for restores from a script or an
    unattended session, since there is no terminal to confirm on
  - use `--db NAME` (repeatable) to restore only specific databases from
    the backup directory instead of everything in it — useful for pulling
    back just `acore_characters` after a bad GM command, for example

**Auto-restore** (`AUTO_RESTORE=1`): at container start, before the
scheduler loop begins, the entrypoint runs `acbackup auto-restore`. It
probes whether `AUTO_RESTORE_PROBE` (default `acore_auth.account`) exists
as a table in MySQL. If the table exists, the database is considered
already populated and auto-restore does nothing. If the probe table is
absent, the database is considered empty, and if a complete backup exists
anywhere in the backup tree, the newest one is restored automatically
(skipping the confirmation prompt and the pre-restore safety backup, since
there is nothing meaningful to protect against loss on an empty database).
This is logged loudly and fires the alert webhook, so it's obvious after
the fact that a restore happened rather than a fresh empty database being
silently used. Auto-restore never touches a non-empty database — there are
no marker files involved in this decision, the database's own contents are
the source of truth. This makes "compose file plus a backup directory" a
complete recipe for rebuilding a server from scratch: point a fresh MySQL
volume and this image's backup volume at the same paths, set
`AUTO_RESTORE=1`, and start the stack.

## NFS and permissions

The container runs `mysqldump`/`mysql`/the scheduler as `PUID:PGID` (default
`1000:1000`), not as root, so that backup files on the mounted volume are
owned by a predictable, non-root uid/gid on the host — this matters a lot
when `/backups` is an NFS mount shared with other tooling, or when you want
to `scp` backups off the host as a regular user.

At startup, the entrypoint (running as root, before dropping privileges)
creates the four tier root directories (`hourly/`, `daily/`, `monthly/`,
`manual/`) if missing and `chown`s/`chmod`s **only those four directories**,
never recursively. This is deliberate: a backup volume can accumulate
months of timestamped subdirectories, and a recursive `chown -R` over an
NFS mount holding a large backup history is slow and, on some NFS setups
with root-squash, will silently fail deep into the tree. Fixing ownership
of just the tier roots is enough for the container to create new
timestamped subdirectories correctly; it does not retroactively fix
ownership of old backups (which generally don't need it, since they were
written correctly the first time).

Within a single backup run, `run_backup` additionally self-heals ownership
drift on just the directory it's writing to: if any file under that
specific timestamped directory isn't owned by the container's runtime user
(which can happen on NFS mounts with root-squash, where root-owned
directory creation and a non-root writer can disagree), it `chown -R`s and
`chmod`s that one backup's directory back to the expected owner. This is
scoped to a single backup directory, not the whole volume, so it stays fast
and safe even on NFS.

If your NFS export uses root-squash, make sure the export maps root to a
uid/gid that either matches `PUID`/`PGID` or has write access to
`/backups` — the entrypoint's initial `mkdir`/`chown` step runs as root on
the container side, but a squashing export will map that to `nobody` (or
another unprivileged mapped user) on the server side. Either export with
`no_root_squash` for this mount, or pre-create the four tier directories on
the NFS server with the right ownership before first start.

## Alerting

Set `BACKUP_ALERT_WEBHOOK` to a URL and the container will `curl -fsS -m 10
-d "azerothcore-backup: <message>" "$BACKUP_ALERT_WEBHOOK"` whenever a
backup is incomplete, a restore fails, or an auto-restore occurs. This is a
plain-text POST, so it works out of the box with
[ntfy.sh](https://ntfy.sh/):

```yaml
environment:
  BACKUP_ALERT_WEBHOOK: https://ntfy.sh/your-topic-here
```

(subscribe to `your-topic-here` in the ntfy app or web UI to get a push
notification). Any endpoint that accepts a POST body works equally well —
point it at a webhook relay, a chat integration, or your own listener.

Separately, the image's Docker `HEALTHCHECK` (`scripts/healthcheck.sh`)
reports unhealthy if MySQL isn't reachable, or if no `*.sql.gz` file
anywhere under `/backups` has been modified within the last
`BACKUP_HEALTHCHECK_MAX_MINUTES` (default `120`) — a freshness check that
catches a scheduler that's silently stopped producing backups, not just one
that's crashed. To avoid a false-unhealthy on a brand-new container before
its first backup has had a chance to run, the freshness check is skipped
during a grace period of `BACKUP_HEALTHCHECK_GRACE_SECONDS` (default
`4500`, i.e. 75 minutes) measured from container uptime; after the grace
period elapses, the freshness window is enforced normally.

## Development

Unit tests exercise `lib.sh`, the scheduler, and the CLI against stubbed
`mysql`/`mysqldump` commands and don't need a real database:

```bash
bash test/unit/test-lib.sh
bash test/unit/test-scheduler.sh
bash test/unit/test-acbackup.sh
```

(or run all of `test/unit/test-*.sh`).

End-to-end tests build the image and run it against a real MySQL container,
covering seed → backup → verify → corruption detection → wipe → restore →
auto-restore:

```bash
bash test/e2e/run.sh 8.4
```

The argument selects the `mysql` image tag to test against (defaults to
`8.4` if omitted).
