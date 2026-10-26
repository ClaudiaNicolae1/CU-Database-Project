#!/bin/bash
# usage: bash scripts/vault_down.sh yourname [off|on]
# Pauses the Vault container (its keys stay in memory) and records what MariaDB does.
# [off|on] sets hashicorp-key-management-use-cache-on-timeout before the test.
WHO=${1:-$USER}
MODE=${2:-off}
T=${T:-240}
PAUSE_AT=${PAUSE_AT:-20}
RESUME_AT=${RESUME_AT:-170}
POLL1=${POLL1:-120}
POLL2=${POLL2:-300}
STEP=${STEP:-5}
CNF=${CNF:-/etc/mysql/mariadb.conf.d/60-encryption.cnf}
mkdir -p results/$WHO
OUT=results/$WHO/vault_down_$MODE

sudo -v
( while true; do sudo -v; sleep 60; done ) &
KEEP=$!
trap 'sudo docker unpause vault >/dev/null 2>&1; pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null' EXIT

wait_up(){
  local i=0
  while [ $i -lt $1 ]; do
    if timeout 10 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1; then return 0; fi
    sleep $STEP
    i=$((i+STEP))
  done
  return 1
}

worker(){
  while [ $(( $(date +%s) - START_EPOCH )) -lt $T ]; do
    id=$((RANDOM*7%200000+1))
    s=$(date +%s.%N)
    if timeout 120 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=$id; SELECT total FROM shop.orders WHERE order_id=$id; UPDATE shop.users SET phone='+49 1' WHERE user_id=$id;" >/dev/null 2>>${OUT}_errors.txt; then st=ok; else st=err; fi
    e=$(date +%s.%N)
    echo "$(awk -v a=$START_EPOCH -v b=$s 'BEGIN{printf "%.0f",b-a}') $1 $st $(awk -v a=$s -v b=$e 'BEGIN{printf "%.2f",b-a}')" >> ${OUT}_rounds.txt
  done
}

echo "use-cache-on-timeout=$MODE, $(mariadb --version)" | tee ${OUT}_events.txt
sudo sed -i '/^hashicorp-key-management-use-cache-on-timeout/d' $CNF
echo "hashicorp-key-management-use-cache-on-timeout = $MODE" | sudo tee -a $CNF > /dev/null
sudo systemctl restart mariadb
wait_up 120 || { echo "MariaDB does not answer before the test starts, stopping" | tee -a ${OUT}_events.txt; exit 1; }

echo "=== A: running server, Vault unreachable" | tee -a ${OUT}_events.txt
: > ${OUT}_rounds.txt
: > ${OUT}_errors.txt
START_EPOCH=$(date +%s)
pids=""
for w in 1 2 3 4; do
  worker $w &
  pids="$pids $!"
done
paused=0
resumed=0
while [ $(( $(date +%s) - START_EPOCH )) -lt $T ]; do
  t=$(( $(date +%s) - START_EPOCH ))
  if [ $paused = 0 ] && [ $t -ge $PAUSE_AT ]; then
    sudo docker pause vault > /dev/null
    echo "vault paused at ${t}s" | tee -a ${OUT}_events.txt
    paused=1
  fi
  if [ $resumed = 0 ] && [ $t -ge $RESUME_AT ]; then
    sudo docker unpause vault > /dev/null
    echo "vault resumed at ${t}s" | tee -a ${OUT}_events.txt
    resumed=1
  fi
  sleep 1
done
wait $pids
sudo docker unpause vault > /dev/null 2>&1

awk '{b=int($1/10)*10; n[b]++; if($3!="ok")e[b]++; s[b]+=$4; if($4>m[b])m[b]=$4} END{for(b in n) printf "%d %d %d %.2f %.2f\n",b,n[b],e[b]+0,s[b]/n[b],m[b]}' ${OUT}_rounds.txt | sort -n | awk 'BEGIN{print "from_s rounds errors avg_s max_s"}{print}' > ${OUT}_summary.txt
cat ${OUT}_summary.txt

echo "=== B: restart MariaDB while Vault is unreachable" | tee -a ${OUT}_events.txt
sudo docker pause vault > /dev/null
BSTART=$(date +%s)
sudo systemctl restart mariadb --no-block
: > ${OUT}_restart.txt
while [ $(( $(date +%s) - BSTART )) -lt $POLL1 ]; do
  t=$(( $(date +%s) - BSTART ))
  st=$(systemctl is-active mariadb)
  if timeout 10 sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1" >/dev/null 2>&1; then q=query_ok; else q=query_fails; fi
  echo "${t}s service=$st $q" | tee -a ${OUT}_restart.txt
  sleep $STEP
done
sudo docker unpause vault > /dev/null
echo "vault resumed $(( $(date +%s) - BSTART ))s after the restart began" | tee -a ${OUT}_events.txt
RSTART=$(date +%s)
if wait_up $POLL2; then
  echo "MariaDB answers $(( $(date +%s) - RSTART ))s after Vault came back" | tee -a ${OUT}_events.txt
else
  echo "MariaDB still not answering ${POLL2}s after Vault came back, restarting once more" | tee -a ${OUT}_events.txt
  sudo systemctl restart mariadb
  if wait_up 120; then echo "recovered after the second restart" | tee -a ${OUT}_events.txt; else echo "STILL DOWN: see journalctl -u mariadb" | tee -a ${OUT}_events.txt; fi
fi

sudo journalctl -u mariadb --since "$(date -d @$START_EPOCH '+%Y-%m-%d %H:%M:%S')" --no-pager 2>/dev/null | grep -iE "vault|hashicorp|encrypt|key|error" | tail -80 > ${OUT}_journal.txt
echo "files: ${OUT}_events.txt ${OUT}_summary.txt ${OUT}_restart.txt ${OUT}_journal.txt"
