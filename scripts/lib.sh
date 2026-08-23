#!/bin/bash
# azerothcore-backup shared library. Source this; do not execute.

BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-/backups}"
HOURLY_DIR="$BACKUP_DIR_BASE/hourly"
DAILY_DIR="$BACKUP_DIR_BASE/daily"
MONTHLY_DIR="$BACKUP_DIR_BASE/monthly"
MANUAL_DIR="$BACKUP_DIR_BASE/manual"
MYSQL_HOST="${MYSQL_HOST:-ac-database}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
RETENTION_HOURS="${BACKUP_RETENTION_HOURS:-6}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
RETENTION_MONTHS="${BACKUP_RETENTION_MONTHS:-12}"
BACKUP_ALERT_WEBHOOK="${BACKUP_ALERT_WEBHOOK:-}"

log() { echo "[$(date '+%F %T')] $*"; }

alert() {
  log "🚨 $*"
  if [ -n "$BACKUP_ALERT_WEBHOOK" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 -d "azerothcore-backup: $*" "$BACKUP_ALERT_WEBHOOK" >/dev/null 2>&1 || \
      log "⚠️  Failed to deliver alert webhook"
  fi
}

init_credentials() {
  if [ -n "${MYSQL_PASSWORD_FILE:-}" ] && [ -f "$MYSQL_PASSWORD_FILE" ]; then
    MYSQL_PASSWORD="$(cat "$MYSQL_PASSWORD_FILE")"
  fi
  export MYSQL_PWD="${MYSQL_PASSWORD:-}"
}

mysql_cmd() { mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" "$@"; }
mysqldump_cmd() { mysqldump -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" "$@"; }

db_exists() {
  local name="$1"
  [ -z "$name" ] && return 1
  mysql_cmd -e "USE \`${name//\`/}\`;" >/dev/null 2>&1
}

database_list() {
  local raw="${BACKUP_DATABASES:-acore_auth acore_world acore_characters}"
  local -a dbs=()
  local d
  declare -A seen=()
  for d in ${raw//,/ }; do
    [ -n "$d" ] || continue
    [ -n "${seen[$d]:-}" ] && continue
    dbs+=("$d"); seen[$d]=1
  done
  if [ -z "${seen[acore_playerbots]:-}" ] && db_exists acore_playerbots; then
    dbs+=("acore_playerbots")
    log "Detected optional database: acore_playerbots (will be backed up)" >&2
  fi
  printf '%s\n' "${dbs[@]}"
}

# A dump is only trustworthy if the gzip stream is intact and mysqldump
# reached its completion trailer (a truncated dump has neither).
verify_dump() {
  local file="$1"
  gunzip -t "$file" 2>/dev/null || return 1
  zcat "$file" 2>/dev/null | tail -1 | grep -q "Dump completed" || return 1
}

is_complete() { [ -f "$1/.backup_complete" ]; }

# run_backup TARGET_DIR TIER_TYPE — dump+verify every database.
# Marker only on full success. Returns 1 if any database failed.
run_backup() {
  local target_dir="$1" tier_type="$2"
  local ts; ts=$(basename "$target_dir")
  mkdir -p "$target_dir"
  log "Starting ${tier_type} backup to $target_dir"
  local -a dbs failed_dbs=()
  mapfile -t dbs < <(database_list)
  local t0; t0=$(date +%s)
  local total_mb=0
  local db
  for db in "${dbs[@]}"; do
    log "Backing up database: $db"
    local size_mb
    size_mb=$(mysql_cmd -s -N -e "SELECT ROUND(SUM(data_length + index_length)/1024/1024,2) AS size_mb FROM information_schema.tables WHERE table_schema = '$db';" 2>/dev/null || echo 0)
    if mysqldump_cmd --single-transaction --routines --triggers --events \
         --hex-blob --quick --lock-tables=false \
         --add-drop-database --databases "$db" 2>/dev/null \
         | gzip -c > "$target_dir/${db}.sql.gz" \
       && verify_dump "$target_dir/${db}.sql.gz"; then
      total_mb=$(awk -v a="$total_mb" -v b="$size_mb" 'BEGIN{printf "%.2f", a+b}')
      log "✅ Backed up and verified $db (${size_mb}MB)"
    else
      log "❌ Failed to back up $db (dump error or verification failure)"
      failed_dbs+=("$db")
      rm -f "$target_dir/${db}.sql.gz" 2>/dev/null || true
    fi
  done
  local dur=$(( $(date +%s) - t0 ))
  local size; size=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
  local mysql_ver; mysql_ver=$(mysql_cmd -s -N -e 'SELECT VERSION();' 2>/dev/null || echo unknown)
  local rate; rate=$(awk -v u="$total_mb" -v d="$dur" 'BEGIN{printf "%.2f", (d>0)?u/d:0}')
  local retention_field="\"retention_days\": ${RETENTION_DAYS}"
  case "$tier_type" in
    hourly|interval) retention_field="\"retention_hours\": ${RETENTION_HOURS}" ;;
    monthly)         retention_field="\"retention_months\": ${RETENTION_MONTHS}" ;;
    manual)          retention_field="\"retention\": \"manual\"" ;;
  esac
  {
    printf '{\n  "timestamp": "%s",\n  "type": "%s",\n' "$ts" "$tier_type"
    printf '  "databases": [%s],\n' "$(printf '"%s",' "${dbs[@]}" | sed 's/,$//')"
    if [ ${#failed_dbs[@]} -eq 0 ]; then printf '  "failed_databases": [],\n'
    else printf '  "failed_databases": [%s],\n' "$(printf '"%s",' "${failed_dbs[@]}" | sed 's/,$//')"; fi
    printf '  "backup_size": "%s",\n  %s,\n  "mysql_version": "%s",\n' "$size" "$retention_field" "$mysql_ver"
    printf '  "performance": {"duration_seconds": %s, "uncompressed_size_mb": %s, "throughput_mb_per_second": %s}\n}\n' "$dur" "$total_mb" "$rate"
  } > "$target_dir/manifest.json"
  # Ownership drift self-heal (NFS root-squash tolerant): this dir only.
  if find "$target_dir" ! -user "$(id -un)" -print -quit 2>/dev/null | grep -q .; then
    chown -R "$(id -u):$(id -g)" "$target_dir" 2>/dev/null || true
    chmod -R u+rwX,g+rX "$target_dir" 2>/dev/null || true
  fi
  if [ ${#failed_dbs[@]} -eq 0 ]; then
    touch "$target_dir/.backup_complete"
    log "Backup complete: $target_dir (size ${size}, ${dur}s)"
    return 0
  fi
  alert "${tier_type} backup ${ts} INCOMPLETE - failed: ${failed_dbs[*]} (no completion marker written)"
  return 1
}

# Newest complete backup across all tiers, by completion marker mtime.
# (Not basename: labeled manual dirs like pre-restore-<ts> or <label>-<ts>
# start with letters, which sort after digits lexicographically, so a
# basename comparison would let them beat every timestamped backup forever.)
newest_complete_backup() {
  local marker
  marker=$(find "$MANUAL_DIR" "$MONTHLY_DIR" "$DAILY_DIR" "$HOURLY_DIR" \
      -mindepth 2 -maxdepth 2 -name '.backup_complete' -printf '%T@ %h\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-)
  [ -n "$marker" ] && echo "$marker" || return 1
}
