#!/bin/bash
# usage: bash scripts/extra/vault_down_more.sh yourname 1|2|3 [off|on]
#  1: does a request that waits for a paused Vault block other sessions?
#  2: does an expired cache entry make an operation fail? (load first, so server CPU time passes the cache timeout)
#  3: a new key version is written right before Vault is paused: does the server notice it?
WHO=${1:-$USER}
S=${2:-1}
MODE=${3:-off}
OPTIME=${OPTIME:-100}
STEP=${STEP:-5}
LOAD=${LOAD:-150}
R1=${R1:-10}
P1=${P1:-12}
U1=${U1:-170}
CNF=${CNF:-/etc/mysql/mariadb.conf.d/60-encryption.cnf}
mkdir -p results/$WHO/extra
OUT=results/$WHO/extra/vault_down_more_s${S}_$MODE
VAULT="sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault"

sudo -v
( while true; do sudo -v; sleep 60; done ) &
KEEP=$!
trap 'sudo docker unpause vault >/dev/null 2>&1; pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null' EXIT

sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1 || { echo "MariaDB or shop.users is not readable right now. Run scripts/verify.sh first."; exit 1; }
$VAULT kv get mariadb/2 >/dev/null 2>&1 || { echo "Key 2 is not in Vault. Run scripts/verify.sh first."; exit 1; }
case $S in 1|2|3) ;; *) echo "scenario must be 1, 2 or 3"; exit 1;; esac

wait_up(){
  local i=0
  while [ $i -lt $1 ]; do
    if timeout 10 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1; then return 0; fi
    sleep $STEP
    i=$((i+STEP))
  done
  return 1
}

ev(){ echo "$1" | tee -a ${OUT}_events.txt; }

op(){
  local s e out rc st
  s=$(date +%s.%N)
  out=$(timeout $OPTIME sudo mariadb -N -e "$2" 2>&1)
  rc=$?
  e=$(date +%s.%N)
  if [ $rc = 0 ]; then st=ok
  elif [ $rc = 124 ]; then st="timeout after ${OPTIME}s"
  else st="error: $(echo "$out" | tr '\n' ' ' | cut -c1-400)"
  fi
  echo "$1 | $st | $(awk -v a=$s -v b=$e 'BEGIN{printf "%.1f",b-a}') s" | tee -a ${OUT}_ops.txt
}

worker(){
  local n=0 err=0 end=$(( $(date +%s) + LOAD )) id
  while [ $(date +%s) -lt $end ]; do
    id=$((RANDOM*7%200000+1))
    if [ "$BURN" = 1 ]; then q="SELECT COUNT(*),SUM(total) FROM shop.orders"; else q="SELECT full_name FROM shop.users WHERE user_id=$id; SELECT total FROM shop.orders WHERE order_id=$id; UPDATE shop.users SET phone='+49 1' WHERE user_id=$id;"; fi
    if ! timeout 120 sudo mariadb -N -e "$q" >/dev/null 2>&1; then err=$((err+1)); fi
    n=$((n+1))
  done
  echo "worker $1: $n rounds, $err errors" >> ${OUT}_load.txt
}

cpu(){ ps -o cputimes= -p "$(systemctl show mariadb -p MainPID --value)" 2>/dev/null | tr -d ' '; }

cold_start(){
  sudo sed -i '/^hashicorp-key-management-use-cache-on-timeout/d' $CNF
  echo "hashicorp-key-management-use-cache-on-timeout = $MODE" | sudo tee -a $CNF > /dev/null
  sudo mariadb -e "DROP TABLE IF EXISTS shop.t_blk, shop.t_paused1, shop.t_paused2" 2>/dev/null
  sudo systemctl restart mariadb
  wait_up 180 || { ev "MariaDB does not answer after the restart, stopping"; exit 1; }
}

START_EPOCH=$(date +%s)
: > ${OUT}_events.txt
: > ${OUT}_ops.txt
: > ${OUT}_load.txt
ev "scenario $S, use-cache-on-timeout=$MODE, $(mariadb --version)"

if [ $S = 1 ]; then
  $VAULT kv get mariadb/3 >/dev/null 2>&1 || $VAULT kv put mariadb/3 data=$(openssl rand -hex 32) >/dev/null
  cold_start
  sudo docker pause vault > /dev/null
  ev "vault paused"
  B0=$(date +%s)
  ( timeout $OPTIME sudo mariadb -e "CREATE TABLE shop.t_blk (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=3" > ${OUT}_bg.txt 2>&1
    echo "background CREATE with key 3 ended with code $? after $(( $(date +%s) - B0 )) s" | tee -a ${OUT}_events.txt ) &
  BG=$!
  sleep 2
  while kill -0 $BG 2>/dev/null; do
    op "while it waits: read users (key 2)" "SELECT full_name FROM shop.users WHERE user_id=1"
    op "while it waits: update users (key 2)" "UPDATE shop.users SET phone='+49 1' WHERE user_id=1"
    op "while it waits: read orders (key 1)" "SELECT total FROM shop.orders WHERE order_id=1"
    sleep 3
  done
  wait $BG
fi

if [ $S = 2 ]; then
  cold_start
  ev "server CPU time at start: $(cpu) s"
  sudo docker pause vault > /dev/null
  ev "vault paused, load for ${LOAD}s"
  pids=""
  for w in 1 2 3 4; do
    worker $w &
    pids="$pids $!"
  done
  wait $pids
  ev "server CPU time after the load: $(cpu) s (the cache timeout counts CPU seconds)"
  cat ${OUT}_load.txt
  op "create encrypted table, key 2 (after the load)" "CREATE TABLE shop.t_paused1 (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=2"
  op "create encrypted table, key 1 (after the load)" "CREATE TABLE shop.t_paused2 (id INT) ENCRYPTED=YES ENCRYPTION_KEY_ID=1"
  op "read users (key 2)" "SELECT full_name FROM shop.users WHERE user_id=1"
fi

if [ $S = 3 ]; then
  LOAD=${LOAD3:-220}
  cold_start
  Q="SELECT NOW(),MIN(min_key_version),MAX(current_key_version),SUM(rotating_or_flushing) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE current_key_id=2 AND name LIKE 'shop/%';"
  echo "time_s min_key_version max_current_version busy" > ${OUT}_progress.txt
  T0=$(date +%s)
  pids=""
  for w in 1 2 3 4; do
    worker $w &
    pids="$pids $!"
  done
  d1=0
  d2=0
  d3=0
  while [ $(( $(date +%s) - T0 )) -lt $LOAD ]; do
    t=$(( $(date +%s) - T0 ))
    if [ $d1 = 0 ] && [ $t -ge $R1 ]; then
      $VAULT kv put mariadb/2 data=$(openssl rand -hex 32) > /dev/null
      ev "new version of key 2 written at ${t}s"
      d1=1
    fi
    if [ $d2 = 0 ] && [ $t -ge $P1 ]; then
      sudo docker pause vault > /dev/null
      ev "vault paused at ${t}s"
      d2=1
    fi
    if [ $d3 = 0 ] && [ $t -ge $U1 ]; then
      sudo docker unpause vault > /dev/null
      ev "vault resumed at ${t}s"
      d3=1
    fi
    echo "$t $(timeout 20 sudo mariadb -N -e "$Q" | awk '{print $3,$4,$5}')" | tee -a ${OUT}_progress.txt
    sleep $STEP
  done
  wait $pids
  cat ${OUT}_load.txt
fi

sudo docker unpause vault > /dev/null 2>&1
sudo mariadb -e "DROP TABLE IF EXISTS shop.t_blk, shop.t_paused1, shop.t_paused2" 2>/dev/null
sudo journalctl -u mariadb --since "$(date -d @$START_EPOCH '+%Y-%m-%d %H:%M:%S')" --no-pager 2>/dev/null | grep -iE "vault|hashicorp|encrypt|key|error" | tail -60 > ${OUT}_journal.txt
echo "files: ${OUT}_events.txt ${OUT}_ops.txt ${OUT}_journal.txt (and _bg, _load, _progress where they apply)"
