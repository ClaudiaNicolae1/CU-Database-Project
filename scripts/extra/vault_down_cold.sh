#!/bin/bash
# usage: bash scripts/extra/vault_down_cold.sh yourname [off|on]
# Restarts MariaDB while Vault is up (cold key cache), pauses Vault at once, then times
# operations that need a key. [off|on] sets hashicorp-key-management-use-cache-on-timeout.
WHO=${1:-$USER}
MODE=${2:-off}
OPTIME=${OPTIME:-100}
STEP=${STEP:-5}
CNF=${CNF:-/etc/mysql/mariadb.conf.d/60-encryption.cnf}
mkdir -p results/$WHO/extra
OUT=results/$WHO/extra/vault_down_cold_$MODE

sudo -v
( while true; do sudo -v; sleep 60; done ) &
KEEP=$!
trap 'sudo docker unpause vault >/dev/null 2>&1; pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null' EXIT

sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1 || { echo "MariaDB or shop.users is not readable right now. Run scripts/verify.sh first."; exit 1; }
sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault kv get mariadb/2 >/dev/null 2>&1 || { echo "Key 2 is not in Vault. Run scripts/verify.sh first."; exit 1; }

wait_up(){
  local i=0
  while [ $i -lt $1 ]; do
    if timeout 10 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1; then return 0; fi
    sleep $STEP
    i=$((i+STEP))
  done
  return 1
}

op(){
  local s e out rc st
  s=$(date +%s.%N)
  out=$(timeout $OPTIME sudo mariadb -N -e "$2" 2>&1)
  rc=$?
  e=$(date +%s.%N)
  if [ $rc = 0 ]; then st=ok
  elif [ $rc = 124 ]; then st="timeout after ${OPTIME}s"
  else st="error: $(echo "$out" | tr '\n' ' ' | cut -c1-150)"
  fi
  echo "$1 | $st | $(awk -v a=$s -v b=$e 'BEGIN{printf "%.1f",b-a}') s" | tee -a ${OUT}_ops.txt
}

echo "use-cache-on-timeout=$MODE, $(mariadb --version)" | tee ${OUT}_events.txt
sudo sed -i '/^hashicorp-key-management-use-cache-on-timeout/d' $CNF
echo "hashicorp-key-management-use-cache-on-timeout = $MODE" | sudo tee -a $CNF > /dev/null
sudo mariadb -e "DROP TABLE IF EXISTS shop.t_paused3, shop.t_paused2, shop.t_paused1" 2>/dev/null
sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault kv get mariadb/3 >/dev/null 2>&1 || sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault kv put mariadb/3 data=$(openssl rand -hex 32) >/dev/null
START_EPOCH=$(date +%s)
sudo systemctl restart mariadb
wait_up 180 || { echo "MariaDB does not answer after the restart, stopping" | tee -a ${OUT}_events.txt; exit 1; }
sudo docker pause vault > /dev/null
echo "restarted with Vault up, Vault paused $(( $(date +%s) - START_EPOCH ))s after the restart began" | tee -a ${OUT}_events.txt

: > ${OUT}_ops.txt
op "read shop.order_items (key 1, cold)" "SELECT COUNT(*) FROM shop.order_items"
op "read shop.payment_methods (key 2, cold)" "SELECT COUNT(*) FROM shop.payment_methods"
op "update one row in shop.users (key 2)" "UPDATE shop.users SET phone='+49 1' WHERE user_id=1"
op "create encrypted table, key 2" "CREATE TABLE shop.t_paused1 (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=2"
op "insert into that table" "INSERT INTO shop.t_paused1 VALUES (1)"
op "create encrypted table, key 1" "CREATE TABLE shop.t_paused2 (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=1"
op "create encrypted table, key 3 (never used since the restart)" "CREATE TABLE shop.t_paused3 (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=3"

sudo docker unpause vault > /dev/null
echo "vault resumed" | tee -a ${OUT}_events.txt
if wait_up 120; then echo "MariaDB answers after Vault came back" | tee -a ${OUT}_events.txt; else echo "MariaDB does not answer after Vault came back: restart it" | tee -a ${OUT}_events.txt; fi
sudo mariadb -e "DROP TABLE IF EXISTS shop.t_paused3, shop.t_paused2, shop.t_paused1" 2>/dev/null

sudo journalctl -u mariadb --since "$(date -d @$START_EPOCH '+%Y-%m-%d %H:%M:%S')" --no-pager 2>/dev/null | grep -iE "vault|hashicorp|encrypt|key|error" | tail -60 > ${OUT}_journal.txt
echo "files: ${OUT}_events.txt ${OUT}_ops.txt ${OUT}_journal.txt"
