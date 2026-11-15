#!/bin/bash
# Usage: bash scripts/enable_binlog_aria.sh plain|encrypted
set -e

MODE=${1:?usage: $0 plain|encrypted}
CONF=/etc/mysql/mariadb.conf.d/70-binlog-aria.cnf

case "$MODE" in
  plain)     ENC=OFF ;;
  encrypted) ENC=ON ;;
  *) echo "usage: $0 plain|encrypted"; exit 1 ;;
esac

# Encryption needs the Vault key plugin to be configured already
if [ "$ENC" = "ON" ] && [ ! -f /etc/mysql/mariadb.conf.d/60-encryption.cnf ]; then
  echo "Run scripts/enable_encryption.sh first (Vault key plugin missing)."
  exit 1
fi

sudo tee "$CONF" > /dev/null << CNF
[mariadb]
log_bin = mariadb-bin
encrypt_binlog = $ENC
aria_encrypt_tables = $ENC
encrypt_tmp_disk_tables = $ENC
CNF

sudo systemctl restart mariadb

# Prove the options were really loaded
sudo mariadb -e "SHOW VARIABLES WHERE Variable_name IN
  ('log_bin','encrypt_binlog','aria_encrypt_tables','encrypt_tmp_disk_tables');"
echo "Binlog and Aria set to: $MODE"