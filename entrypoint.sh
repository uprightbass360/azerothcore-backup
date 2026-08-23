#!/bin/bash
# Entrypoint: fix tier-root ownership, drop privileges, dispatch.
set -u

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-/backups}"

# Container-start stamp for the healthcheck's startup grace period (measures
# container uptime, not host uptime - /proc/uptime is the host's in Docker).
date +%s > /run/acbackup.started

# Tier roots only - never recursive over months of (possibly NFS) backups.
mkdir -p "$BACKUP_DIR_BASE"/{hourly,daily,monthly,manual}
chown "$PUID:$PGID" "$BACKUP_DIR_BASE" "$BACKUP_DIR_BASE"/{hourly,daily,monthly,manual} 2>/dev/null || true
chmod u+rwx "$BACKUP_DIR_BASE" "$BACKUP_DIR_BASE"/{hourly,daily,monthly,manual} 2>/dev/null || true

run_as() { gosu "$PUID:$PGID" "$@"; }

if [ "$#" -gt 0 ] && [ "$1" != "scheduler" ]; then
  # One-shot mode: e.g. `docker run ... acbackup list`
  exec gosu "$PUID:$PGID" "$@"
fi

if [ "${AUTO_RESTORE:-0}" = "1" ]; then
  run_as /opt/acbackup/acbackup auto-restore || echo "⚠️  auto-restore failed; continuing to scheduler" >&2
fi

exec gosu "$PUID:$PGID" /opt/acbackup/backup-scheduler.sh
