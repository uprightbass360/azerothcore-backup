#!/bin/bash
# e2e: seed -> backup -> verify -> corrupt-detect -> wipe -> restore -> auto-restore.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
export MYSQL_TAG="${1:-8.4}"
C="docker compose -f compose.yml -p acbk-e2e"
fail(){ echo "E2E FAIL: $*"; $C logs backup | tail -20; $C down -v --remove-orphans >/dev/null 2>&1; exit 1; }
cleanup(){
  $C down -v --remove-orphans >/dev/null 2>&1 || true
  # ./volume holds files the container wrote as uid 1234 (NFS-ish skew vs the
  # runner's own uid) - a plain rm can't remove those without root. Try sudo
  # first (CI runners often have it); if that's unavailable/non-interactive,
  # fall back to deleting via a throwaway container running as the same uid.
  if [ -d ./volume ]; then
    sudo -n rm -rf ./volume 2>/dev/null \
      || rm -rf ./volume 2>/dev/null \
      || docker run --rm -v "$PWD/volume:/v" alpine sh -c 'rm -rf /v/*' 2>/dev/null
    rmdir ./volume 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== e2e against mysql:$MYSQL_TAG ==="
rm -rf ./volume && mkdir -p ./volume   # owned by runner uid, container uses 1234 (NFS-ish skew)
$C up -d --wait db
$C exec -T db mysql -uroot -pe2epass < seed.sql

$C up -d backup
sleep 5

echo "--- backup via acbackup now ---"
$C exec -T backup acbackup now --label e2e || fail "acbackup now failed"
B=$($C exec -T backup sh -c 'ls -d /backups/manual/e2e-* | head -1' | tr -d '\r')
[ -n "$B" ] || fail "no manual backup dir"
$C exec -T backup sh -c "test -f $B/.backup_complete" || fail "missing completion marker"
$C exec -T backup sh -c "ls $B/acore_playerbots.sql.gz" >/dev/null || fail "playerbots not auto-detected"

echo "--- verify passes, corrupt copy fails ---"
$C exec -T backup acbackup verify "$B" || fail "verify rejected good backup"
$C exec -T backup sh -c "cp -r $B /backups/manual/corrupt && truncate -s 30 /backups/manual/corrupt/acore_world.sql.gz"
# Deliberate-corruption assertion: the rejection output (with its ❌ lines)
# is captured and shown ONLY if the assertion fails, so a passing run's log
# never contains a spurious failure marker. A real failure (verify
# accepting the corrupt copy) prints the evidence and trips the gate.
if corrupt_out=$($C exec -T backup acbackup verify /backups/manual/corrupt 2>&1); then
  echo "$corrupt_out"
  fail "verify accepted corrupt backup"
else
  echo "corrupted backup correctly rejected (rejection output suppressed)"
fi
# The cp -r carried over the good backup's .backup_complete marker, which
# never went through real verification for this directory - drop it so this
# intentionally-corrupt fixture can't be mistaken for a real completed
# backup by newest_complete_backup (which trusts the marker, same as
# production: only run_backup is supposed to write one, and only after
# every dump verifies).
$C exec -T backup sh -c "rm -f /backups/manual/corrupt/.backup_complete"

echo "--- wipe and restore ---"
$C exec -T db mysql -uroot -pe2epass -e "DROP DATABASE acore_characters; DROP DATABASE acore_auth;"
$C exec -T backup acbackup restore "$B" --yes --no-safety-backup || fail "restore failed"
N=$($C exec -T db mysql -uroot -pe2epass -N -B -e "SELECT COUNT(*) FROM acore_characters.characters;" | tr -d '\r')
[ "$N" = "2" ] || fail "row count after restore: $N (want 2)"

echo "--- auto-restore on empty server ---"
$C exec -T db mysql -uroot -pe2epass -e "DROP DATABASE acore_auth;"
$C stop backup >/dev/null
$C rm -f backup >/dev/null 2>&1 || true
AUTO_RESTORE=1 $C up -d backup
$C exec -T backup true  # wait for container
for i in $(seq 1 30); do
  R=$($C exec -T db mysql -uroot -pe2epass -N -B -e "SELECT COUNT(*) FROM acore_auth.account;" 2>/dev/null | tr -d '\r' || echo "")
  [ "$R" = "2" ] && break
  sleep 2
done
[ "$R" = "2" ] || fail "auto-restore did not repopulate acore_auth (got '$R')"

echo "=== E2E PASS (mysql:$MYSQL_TAG) ==="
