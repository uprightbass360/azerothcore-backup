#!/bin/bash
# azerothcore-backup scheduler: interval + daily + monthly tiers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
init_credentials

# Force base-10 (a bare printf %02d rejects "09" as invalid octal)
DAILY_TIME=$(printf '%02d' "$((10#${BACKUP_DAILY_TIME:-09}))" 2>/dev/null || echo "09")
BACKUP_INTERVAL_MINUTES="${BACKUP_INTERVAL_MINUTES:-60}"

mkdir -p "$HOURLY_DIR" "$DAILY_DIR" "$MONTHLY_DIR" "$MANUAL_DIR"

cleanup_old() {
  find "$HOURLY_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +$((RETENTION_HOURS*60)) -exec rm -rf {} + 2>/dev/null || true
  find "$DAILY_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true
  find "$MONTHLY_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$((RETENTION_MONTHS*31)) -exec rm -rf {} + 2>/dev/null || true
}

# Promote the first complete daily backup of each month into the monthly tier.
promote_monthly() {
  local month; month=$(date '+%Y%m')
  find "$MONTHLY_DIR" -mindepth 1 -maxdepth 1 -type d -name "${month}*" -print -quit 2>/dev/null | grep -q . && return 0
  local candidate
  candidate=$(find "$DAILY_DIR" -mindepth 1 -maxdepth 1 -type d -name "${month}*" 2>/dev/null | sort | while read -r d; do
    is_complete "$d" && echo "$d" && break
  done)
  if [ -n "$candidate" ]; then
    if cp -a "$candidate" "$MONTHLY_DIR/$(basename "$candidate")"; then
      log "📦 Promoted $(basename "$candidate") to monthly tier"
    else
      log "⚠️  Failed to promote $(basename "$candidate") to monthly tier"
    fi
  fi
}

if [ "${SCHEDULER_ONE_SHOT:-0}" = "1" ]; then
  log "Backup scheduler starting: interval(${BACKUP_INTERVAL_MINUTES}m), daily(${RETENTION_DAYS}d at ${DAILY_TIME}:00), monthly(${RETENTION_MONTHS}mo)"
  run_backup "$HOURLY_DIR/$(date '+%Y%m%d_%H%M%S')" interval
  rc=$?
  cleanup_old
  exit "$rc"
fi

log "Backup scheduler starting: interval(${BACKUP_INTERVAL_MINUTES}m), daily(${RETENTION_DAYS}d at ${DAILY_TIME}:00), monthly(${RETENTION_MONTHS}mo)"
last_backup=$(date +%s)
# Seed the daily tracker from disk so a restart neither skips nor duplicates.
last_daily_date=""
if find "$DAILY_DIR" -mindepth 1 -maxdepth 1 -type d -name "$(date '+%Y%m%d')_*" -print -quit 2>/dev/null | grep -q .; then
  last_daily_date=$(date '+%F')
fi
log "ℹ️  First backup will run in ${BACKUP_INTERVAL_MINUTES} minutes"

while true; do
  now=$(date +%s); hour=$(date '+%H'); today=$(date '+%F')
  if [ $((now - last_backup)) -ge $((BACKUP_INTERVAL_MINUTES * 60)) ]; then
    run_backup "$HOURLY_DIR/$(date '+%Y%m%d_%H%M%S')" interval || true
    last_backup=$now
  fi
  # Daily fires once per day at-or-after DAILY_TIME (date-tracked, so a slow
  # interval backup spanning the top of the hour cannot skip the day).
  if [ "$hour" -ge "$DAILY_TIME" ] 2>/dev/null && [ "$last_daily_date" != "$today" ]; then
    run_backup "$DAILY_DIR/$(date '+%Y%m%d_%H%M%S')" daily || true
    last_daily_date="$today"
    promote_monthly
  fi
  cleanup_old
  sleep 60
done
