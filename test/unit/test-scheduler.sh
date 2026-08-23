#!/bin/bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HERE/stubs:$PATH"
TMP="$ROOT/test/tmp/sched.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
export BACKUP_DIR_BASE="$TMP/backups" MYSQL_HOST=stub MYSQL_USER=root MYSQL_PASSWORD=x
export STUB_EXISTING_DBS="acore_auth acore_world acore_characters"
pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }; bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# One-shot mode: performs an interval backup then exits 0
SCHEDULER_ONE_SHOT=1 bash "$ROOT/scripts/backup-scheduler.sh" >/dev/null 2>&1
n=$(find "$BACKUP_DIR_BASE/hourly" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$n" -eq 1 ] && ok "one-shot produced one interval backup" || bad "expected 1 hourly dir, got $n"
d=$(find "$BACKUP_DIR_BASE/hourly" -mindepth 1 -maxdepth 1 -type d)
[ -f "$d/.backup_complete" ] && ok "one-shot backup complete" || bad "one-shot backup incomplete"

# Tier dirs all exist after startup
for t in hourly daily monthly manual; do
  [ -d "$BACKUP_DIR_BASE/$t" ] && ok "tier dir $t created" || bad "tier dir $t missing"
done

# DAILY_TIME normalization: "9" and "09" both become "09"
line=$(BACKUP_DAILY_TIME=9 SCHEDULER_ONE_SHOT=1 bash "$ROOT/scripts/backup-scheduler.sh" 2>/dev/null | grep "scheduler starting")
echo "$line" | grep -q "at 09:00" && ok "DAILY_TIME zero-padded" || bad "DAILY_TIME wrong: $line"

# Readiness gate (loop mode): probe absent -> waits, then proceeds on timeout
rm -rf "$BACKUP_DIR_BASE"
glog=$(STUB_ACCOUNT_TABLE=0 BACKUP_READY_TIMEOUT_SECONDS=10 BACKUP_DAILY_TIME=23 \
  BACKUP_INTERVAL_MINUTES=999 timeout 16 bash "$ROOT/scripts/backup-scheduler.sh" 2>/dev/null)
echo "$glog" | grep -q "Waiting for database import" && ok "gate waits when probe absent" || bad "gate did not wait"
echo "$glog" | grep -q "proceeding anyway" && ok "gate proceeds after timeout" || bad "gate never timed out"

# Readiness gate: probe present -> ready immediately; post-DAILY_TIME fresh
# start announces and takes the immediate daily
rm -rf "$BACKUP_DIR_BASE"
glog=$(STUB_ACCOUNT_TABLE=1 BACKUP_READY_TIMEOUT_SECONDS=60 BACKUP_DAILY_TIME=00 \
  BACKUP_INTERVAL_MINUTES=999 timeout 8 bash "$ROOT/scripts/backup-scheduler.sh" 2>/dev/null)
echo "$glog" | grep -q "Database ready" && ok "gate passes when probe present" || bad "gate blocked despite ready probe"
echo "$glog" | grep -q "taking one now" && ok "post-daily-time start announces immediate daily" || bad "immediate-daily announcement missing"
n=$(find "$BACKUP_DIR_BASE/daily" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$n" -eq 1 ] && ok "immediate daily taken after gate" || bad "expected 1 daily dir, got $n"

# Readiness gate disabled with timeout 0
rm -rf "$BACKUP_DIR_BASE"
glog=$(STUB_ACCOUNT_TABLE=0 BACKUP_READY_TIMEOUT_SECONDS=0 BACKUP_DAILY_TIME=23 \
  BACKUP_INTERVAL_MINUTES=999 timeout 4 bash "$ROOT/scripts/backup-scheduler.sh" 2>/dev/null)
echo "$glog" | grep -q "Waiting for database import" && bad "gate ran despite timeout 0" || ok "gate disabled by timeout 0"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
