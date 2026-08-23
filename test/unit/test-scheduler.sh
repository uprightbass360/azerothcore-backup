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

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
