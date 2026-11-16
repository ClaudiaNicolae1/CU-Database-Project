#!/bin/bash
# Usage: bash scripts/binlog_leak_test.sh (yourname)
# Shows that the binary log keeps a statement in plain text even when the
# table it changes is encrypted, and that encrypt_binlog closes this.
set -e
cd "$(dirname "$0")/.." || exit 1
WHO=${1:-$USER}
sudo -v
DATADIR=$(sudo mariadb -N -e "SELECT @@datadir;")
mkdir -p results/$WHO
OUT=results/$WHO/binlog_leak_test.txt
TAG=MARKER-$(date +%s)   # a new marker each run, so old logs do not confuse the result

look() {   # look <label> <file> <text>
  echo "-- $1"
  sudo sh -c "strings $2 | grep $3" || echo "   (not found)"
}

{
  echo "### marker: $TAG   datadir: $DATADIR"
  sudo mariadb -e "ALTER TABLE shop.users ENCRYPTED=YES ENCRYPTION_KEY_ID=2;"
  sudo mariadb -N -e "SELECT name, encryption_scheme, current_key_id FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name='shop/users';"

  bash scripts/enable_binlog_aria.sh plain > /dev/null
  sudo mariadb -e "UPDATE shop.users SET phone='$TAG-PLAIN' WHERE user_id=1; FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES;"
  look "table file (encrypted table)" "${DATADIR}shop/users.ibd" "$TAG-PLAIN"
  look "binary log NOT encrypted" "${DATADIR}mariadb-bin.0*" "$TAG-PLAIN"

  bash scripts/enable_binlog_aria.sh encrypted > /dev/null
  sudo mariadb -e "UPDATE shop.users SET phone='$TAG-ENC' WHERE user_id=1; FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES;"
  look "table file (encrypted table)" "${DATADIR}shop/users.ibd" "$TAG-ENC"
  look "binary log encrypted" "${DATADIR}mariadb-bin.0*" "$TAG-ENC"
} | tee "$OUT"