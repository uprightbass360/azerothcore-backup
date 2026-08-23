#!/bin/bash
# Unit tests for scripts/lib.sh using PATH stubs. No Docker required.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HERE/stubs:$PATH"
TMP="$ROOT/test/tmp/lib.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
export BACKUP_DIR_BASE="$TMP/backups"
export MYSQL_HOST=stub MYSQL_USER=root MYSQL_PASSWORD=x
export BACKUP_ALERT_WEBHOOK=""
export STUB_EXISTING_DBS="acore_auth acore_world acore_characters acore_playerbots"

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }

source "$ROOT/scripts/lib.sh"
init_credentials

# database_list: defaults + playerbots auto-add
list=$(database_list | tr '\n' ' ')
[ "$list" = "acore_auth acore_world acore_characters acore_playerbots " ] \
  && ok "database_list defaults + playerbots" || bad "database_list got: $list"

# database_list: explicit BACKUP_DATABASES, comma form, no duplicate playerbots
list=$(BACKUP_DATABASES="acore_auth,acore_playerbots" database_list | tr '\n' ' ')
[ "$list" = "acore_auth acore_playerbots " ] \
  && ok "database_list comma + no dup" || bad "database_list custom got: $list"

# verify_dump: good and truncated
printf -- '-- dump\n-- Dump completed on x\n' | gzip > "$TMP/good.sql.gz"
printf -- '-- dump\nno trailer\n' | gzip > "$TMP/trunc.sql.gz"
verify_dump "$TMP/good.sql.gz" && ok "verify_dump accepts complete" || bad "verify_dump rejected good"
verify_dump "$TMP/trunc.sql.gz" && bad "verify_dump accepted truncated" || ok "verify_dump rejects truncated"

# run_backup success: marker + manifest type + empty failed list
run_backup "$BACKUP_DIR_BASE/hourly/one" interval >/dev/null 2>&1
[ -f "$BACKUP_DIR_BASE/hourly/one/.backup_complete" ] && ok "marker on success" || bad "no marker on success"
python3 - "$BACKUP_DIR_BASE/hourly/one/manifest.json" <<'PY' && ok "manifest valid+correct" || bad "manifest bad"
import json,sys
m=json.load(open(sys.argv[1]))
assert m["type"]=="interval" and m["failed_databases"]==[] and "retention_hours" in m
PY

# run_backup failure: no marker, failed db recorded, dump removed
STUB_FAIL_DB=acore_world run_backup "$BACKUP_DIR_BASE/hourly/two" interval >/dev/null 2>&1
[ ! -f "$BACKUP_DIR_BASE/hourly/two/.backup_complete" ] && ok "no marker on failure" || bad "marker written on failure"
[ ! -f "$BACKUP_DIR_BASE/hourly/two/acore_world.sql.gz" ] && ok "failed dump removed" || bad "failed dump kept"
python3 - "$BACKUP_DIR_BASE/hourly/two/manifest.json" <<'PY' && ok "failed_databases recorded" || bad "failed_databases wrong"
import json,sys; assert json.load(open(sys.argv[1]))["failed_databases"]==["acore_world"]
PY

# newest_complete_backup: prefers newest complete across tiers, skips incomplete
mkdir -p "$BACKUP_DIR_BASE/daily/20260101_000000" && touch "$BACKUP_DIR_BASE/daily/20260101_000000/.backup_complete"
mkdir -p "$BACKUP_DIR_BASE/manual/20270101_000000"   # newer but incomplete
n=$(newest_complete_backup)
case "$n" in */hourly/one) ok "newest_complete_backup picks newest complete";; *) bad "newest picked: $n";; esac

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
