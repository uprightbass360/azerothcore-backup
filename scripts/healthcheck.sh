#!/bin/bash
# Healthy when MySQL is reachable AND a recent dump exists (or still in grace).
set -u
MAX_MIN="${BACKUP_HEALTHCHECK_MAX_MINUTES:-120}"
GRACE_S="${BACKUP_HEALTHCHECK_GRACE_SECONDS:-4500}"
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-/backups}"
export MYSQL_PWD="${MYSQL_PASSWORD:-}"
mysql -h"${MYSQL_HOST:-ac-database}" -P"${MYSQL_PORT:-3306}" -u"${MYSQL_USER:-root}" -e 'SELECT 1' >/dev/null 2>&1 || exit 1
find "$BACKUP_DIR_BASE" -name '*.sql.gz' -mmin "-$MAX_MIN" -print -quit 2>/dev/null | grep -q . && exit 0
awk -v limit="$GRACE_S" 'NR==1 { exit ($1 < limit) ? 0 : 1 }' /proc/uptime
