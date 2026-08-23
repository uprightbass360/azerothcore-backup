#!/bin/bash
# Healthy when MySQL is reachable AND a recent dump exists (or still in grace).
set -u
MAX_MIN="${BACKUP_HEALTHCHECK_MAX_MINUTES:-120}"
GRACE_S="${BACKUP_HEALTHCHECK_GRACE_SECONDS:-4500}"
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-/backups}"
STARTED_FILE="${ACBACKUP_STARTED_FILE:-/run/acbackup.started}"
if [ -n "${MYSQL_PASSWORD_FILE:-}" ] && [ -f "$MYSQL_PASSWORD_FILE" ]; then
  MYSQL_PASSWORD="$(cat "$MYSQL_PASSWORD_FILE")"
fi
export MYSQL_PWD="${MYSQL_PASSWORD:-}"
mysql -h"${MYSQL_HOST:-ac-database}" -P"${MYSQL_PORT:-3306}" -u"${MYSQL_USER:-root}" -e 'SELECT 1' >/dev/null 2>&1 || exit 1
find "$BACKUP_DIR_BASE" -name '*.sql.gz' -mmin "-$MAX_MIN" -print -quit 2>/dev/null | grep -q . && exit 0
if [ ! -f "$STARTED_FILE" ]; then
  # No stamp (unexpected entrypoint bypass) - don't false-flag as unhealthy.
  exit 0
fi
started=$(cat "$STARTED_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
elapsed=$(( now - started ))
[ "$elapsed" -lt "$GRACE_S" ] && exit 0
exit 1
