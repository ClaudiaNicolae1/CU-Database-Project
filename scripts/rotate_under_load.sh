#!/bin/bash
# usage: bash scripts/rotate_under_load.sh yourname
# Rotates key 2 (the personal-data tables) twice while workers keep querying the shop tables,
# and records what MariaDB does. Run it when verify.sh passes and Vault is up.
# Workers: full-table scans (they use a lot of server CPU time, which the plugin's cache timers count)
# and reads and updates on the key 2 tables.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
WHO=${1:-$USER}
T=${T:-240}
V2=${V2:-20}
V3=${V3:-60}
STEP=${STEP:-5}
BURNERS=${BURNERS:-4}
POINTERS=${POINTERS:-2}
mkdir -p results/$WHO
OUT=results/$WHO/rotation
RAW=$(mktemp /tmp/rotation_rounds.XXXXXX)
VAULT="sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault"
Q="SELECT IFNULL(MIN(min_key_version),0), IFNULL(MAX(current_key_version),0), IFNULL(SUM(rotating_or_flushing),0), (SELECT variable_value FROM information_schema.GLOBAL_STATUS WHERE variable_name='INNODB_ENCRYPTION_ROTATION_PAGES_MODIFIED') FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE current_key_id=2 AND name LIKE 'shop/%'"

sudo -v || exit 1
( while true; do sudo -v; sleep 60; done ) &
KEEP=$!
pids=""
cleanup(){ [ -n "$pids" ] && kill $pids 2>/dev/null; pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null; rm -f $RAW; }
trap cleanup EXIT

sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1 || { echo "rotate_under_load.sh: MariaDB or shop.users is not readable. Run scripts/verify.sh first."; exit 1; }
$VAULT kv get mariadb/2 >/dev/null 2>&1 || { echo "rotate_under_load.sh: key 2 is not in Vault. Run scripts/verify.sh first."; exit 1; }
n=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE current_key_id=2 AND encryption_scheme=1 AND name LIKE 'shop/%'" 2>/dev/null)
[ "$n" = 3 ] || { echo "rotate_under_load.sh: expected 3 shop tables encrypted with key 2, found '$n'. Run scripts/verify.sh first."; exit 1; }

START=$(date +%s)
burner(){
  local s e st
  while [ $(( $(date +%s) - START )) -lt $T ]; do
    s=$(date +%s.%N)
    if timeout 120 sudo mariadb -N -e "SELECT COUNT(*),SUM(total) FROM shop.orders" >/dev/null 2>&1; then st=ok; else st=err; fi
    e=$(date +%s.%N)
    echo "$(awk -v a=$START -v b=$s 'BEGIN{printf "%.0f",b-a}') scan $st $(awk -v a=$s -v b=$e 'BEGIN{printf "%.2f",b-a}')" >> $RAW
  done
}
pointer(){
  local id s e st
  while [ $(( $(date +%s) - START )) -lt $T ]; do
    id=$((RANDOM*7%200000+1))
    s=$(date +%s.%N)
    if timeout 120 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=$id; SELECT street FROM shop.addresses WHERE user_id=$id; SELECT card_last4 FROM shop.payment_methods WHERE user_id=$id; UPDATE shop.users SET phone='+49 1' WHERE user_id=$id" >/dev/null 2>&1; then st=ok; else st=err; fi
    e=$(date +%s.%N)
    echo "$(awk -v a=$START -v b=$s 'BEGIN{printf "%.0f",b-a}') point $st $(awk -v a=$s -v b=$e 'BEGIN{printf "%.2f",b-a}')" >> $RAW
  done
}

echo "start $(date +%T), load for ${T}s: $BURNERS scan workers and $POINTERS point workers" | tee ${OUT}_events.txt
echo "time_s min_key_version max_current_version still_rotating pages_re-encrypted" > ${OUT}_progress.txt
for i in $(seq 1 $BURNERS); do burner & pids="$pids $!"; done
for i in $(seq 1 $POINTERS); do pointer & pids="$pids $!"; done

d1=0
d2=0
while [ $(( $(date +%s) - START )) -lt $T ]; do
  t=$(( $(date +%s) - START ))
  if [ $d1 = 0 ] && [ $t -ge $V2 ]; then
    $VAULT kv put mariadb/2 data=$(openssl rand -hex 32) > /dev/null || { echo "rotate_under_load.sh: could not write the new key version to Vault"; exit 1; }
    echo "new version of key 2 written at ${t}s (first)" | tee -a ${OUT}_events.txt
    d1=1
  fi
  if [ $d2 = 0 ] && [ $t -ge $V3 ]; then
    $VAULT kv put mariadb/2 data=$(openssl rand -hex 32) > /dev/null || { echo "rotate_under_load.sh: could not write the new key version to Vault"; exit 1; }
    echo "new version of key 2 written at ${t}s (second)" | tee -a ${OUT}_events.txt
    d2=1
  fi
  r=$(timeout 20 sudo mariadb -N -e "$Q" 2>/dev/null | tr '\t' ' ')
  echo "$t $r" | tee -a ${OUT}_progress.txt
  sleep $STEP
done
wait $pids
pids=""

{
  echo "== key versions seen by MariaDB (from ${OUT}_progress.txt)"
  awk -v v2=$V2 -v v3=$V3 'NR>1 && NF>=5 { if(!seen){p0=$5; m0=$3; seen=1} if(!s2 && $3>=m0+1) s2=$1; if(!s3 && $3>=m0+2) s3=$1; lt=$1; mn=$2; mx=$3; b=$4; p=$5 }
    END { if(v2>=9999) print "control run: no new key version was written"; else { if(s2!="") printf "first new key version visible at %ss (written at %ss)\n", s2, v2; else print "first new key version was not seen during the run";
          if(s3!="") printf "second new key version visible at %ss (written at %ss)\n", s3, v3; else print "second new key version was not seen during the run"; }
          printf "at the end (%ss): min_key_version=%s max_current_version=%s still_rotating=%s, pages re-encrypted during the run=%d\n", lt, mn, mx, b, p-p0 }' ${OUT}_progress.txt
  echo
  for ty in scan point; do
    echo "== $ty workers, per 10 s: rounds, errors, average and slowest round in seconds"
    awk -v ty=$ty '$2==ty {b=int($1/10)*10; n[b]++; if($3!="ok")e[b]++; s[b]+=$4; if($4>m[b])m[b]=$4} END{for(b in n) printf "%d %d %d %.2f %.2f\n",b,n[b],e[b]+0,s[b]/n[b],m[b]}' $RAW | sort -n | awk 'BEGIN{print "from_s rounds errors avg_s max_s"} {print}'
    awk -v ty=$ty '$2==ty {tn++; te+=($3!="ok")} END{printf "total: %d rounds, %d errors\n", tn, te}' $RAW
    echo
  done
} | tee ${OUT}_summary.txt
echo "files: ${OUT}_events.txt ${OUT}_progress.txt ${OUT}_summary.txt"
