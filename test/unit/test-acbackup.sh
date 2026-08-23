#!/bin/bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="$HERE/stubs:$PATH"
TMP="$ROOT/test/tmp/cli.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
export BACKUP_DIR_BASE="$TMP/backups" MYSQL_HOST=stub MYSQL_USER=root MYSQL_PASSWORD=x
export STUB_EXISTING_DBS="acore_auth acore_world acore_characters"
CLI="$ROOT/scripts/acbackup"
pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }; bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# 'now' creates a complete manual backup with label
"$CLI" now --label pretest >/dev/null 2>&1
d=$(find "$BACKUP_DIR_BASE/manual" -mindepth 1 -maxdepth 1 -type d -name 'pretest-*' | head -1)
[ -n "$d" ] && [ -f "$d/.backup_complete" ] && ok "now: labeled complete backup" || bad "now failed"

# 'verify' passes the good backup, fails a corrupted copy
"$CLI" verify "$d" >/dev/null 2>&1 && ok "verify accepts complete backup" || bad "verify rejected good"
cp -r "$d" "$TMP/corrupt"; truncate -s 20 "$TMP/corrupt/acore_world.sql.gz"
"$CLI" verify "$TMP/corrupt" >/dev/null 2>&1 && bad "verify accepted corrupt" || ok "verify rejects corrupt"

# 'verify latest' resolves to newest complete
"$CLI" verify latest >/dev/null 2>&1 && ok "verify latest resolves" || bad "verify latest failed"

# 'list' shows the backup and its status
"$CLI" list 2>/dev/null | grep -q "pretest" && ok "list shows backup" || bad "list missing backup"

# 'restore' refuses an incomplete backup
mkdir -p "$BACKUP_DIR_BASE/manual/20200101_000000"   # no marker
"$CLI" restore "$BACKUP_DIR_BASE/manual/20200101_000000" --yes --no-safety-backup >/dev/null 2>&1 \
  && bad "restore accepted incomplete" || ok "restore refuses incomplete"

# 'restore --yes' on complete backup: stub mysql accepts piped input -> success
"$CLI" restore "$d" --yes --no-safety-backup >/dev/null 2>&1 && ok "restore applies complete backup" || bad "restore failed"

# 'restore' without --yes and no TTY: refuses (no hang)
echo | "$CLI" restore "$d" --no-safety-backup >/dev/null 2>&1 && bad "restore ran without confirmation" || ok "restore requires confirmation"

# auto-restore: probe says empty -> restores; probe says populated -> no-op
out=$(STUB_ACCOUNT_TABLE=0 "$CLI" auto-restore 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -qi "restoring" && ok "auto-restore restores when empty" || bad "auto-restore empty path: rc=$rc"
out=$(STUB_ACCOUNT_TABLE=1 "$CLI" auto-restore 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -qi "populated" && ok "auto-restore no-op when populated" || bad "auto-restore populated path: rc=$rc"

echo; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
