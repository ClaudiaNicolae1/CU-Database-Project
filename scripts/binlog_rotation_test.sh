#!/bin/bash
# Usage: bash scripts/binlog_rotation_test.sh (yourname)
# Rotates key 1 in Vault while encrypt_binlog=ON, switches to a new binary log,
# and verifies both old (v1) and new (v2) logs remain encrypted on disk yet readable via SQL.
set -e
cd "$(dirname "$0")/.." || exit 1
WHO=${1:-$USER}
sudo -v
mkdir -p results/$WHO
OUT=results/$WHO/binlog_rotation_test.txt
DATADIR=$(sudo mariadb -N -e "SELECT @@datadir;")
VAULT="sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault"
TAG=ROTMARKER-$(date +%s)

{
  echo "### marker: $TAG   encrypt_binlog=$(sudo mariadb -N -e 'SELECT @@encrypt_binlog;')"
  OLD_LOG=$(sudo mariadb -N -e "SHOW MASTER STATUS;" | awk '{print $1}')
  echo "-- before rotation: active binlog = $OLD_LOG"
  sudo mariadb -e "UPDATE shop.users SET phone='$TAG-V1' WHERE user_id=1;"

  echo "-- rotating key mariadb/1 in Vault and waiting 62s for cache timeout..."
  $VAULT kv put mariadb/1 data=$(openssl rand -hex 32) > /dev/null
  sleep 62

  sudo mariadb -e "FLUSH BINARY LOGS;"
  NEW_LOG=$(sudo mariadb -N -e "SHOW MASTER STATUS;" | awk '{print $1}')
  echo "-- after rotation: active binlog = $NEW_LOG"
  sudo mariadb -e "UPDATE shop.users SET phone='$TAG-V2' WHERE user_id=1;"
  sudo mariadb -e "FLUSH BINARY LOGS;"

  echo "-- disk check (strings) on old log ($OLD_LOG, key v1):"
  sudo strings "${DATADIR}${OLD_LOG}" | grep "$TAG" || echo "   (not found in plain text)"
  echo "-- disk check (strings) on new log ($NEW_LOG, key v2):"
  sudo strings "${DATADIR}${NEW_LOG}" | grep "$TAG" || echo "   (not found in plain text)"

  echo "-- SQL decryption check (SHOW BINLOG EVENTS):"
  OLD_EV=$(sudo mariadb -N -e "SHOW BINLOG EVENTS IN '$OLD_LOG' LIMIT 5;" | wc -l)
  NEW_EV=$(sudo mariadb -N -e "SHOW BINLOG EVENTS IN '$NEW_LOG' LIMIT 5;" | wc -l)
  echo "   events decoded in $OLD_LOG (v1): $OLD_EV"
  echo "   events decoded in $NEW_LOG (v2): $NEW_EV"
} | tee "$OUT"
