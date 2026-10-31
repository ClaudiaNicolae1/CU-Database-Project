#!/bin/bash
# usage: bash scripts/run_all.sh yourname
# Runs every step of the project in order on a fresh Ubuntu 24.04 machine and stops at the first failure.
# DRY_RUN=1 bash scripts/run_all.sh yourname   prints the steps without running them.
NAME=${1:-$USER}
cd "$(dirname "$0")/.." || exit 1
mkdir -p results/$NAME
LOG=results/$NAME/run_all.log
STEPS=12
n=0

run(){
  n=$((n+1))
  echo "[$n/$STEPS] $1" | tee -a $LOG
  if [ -n "$DRY_RUN" ]; then return 0; fi
  shift
  "$@" 2>&1 | tee -a $LOG
  rc=${PIPESTATUS[0]}
  if [ $rc != 0 ]; then
    echo "STOPPED: step $n failed with exit code $rc. See $LOG" | tee -a $LOG
    exit $rc
  fi
}

wait_encrypted(){
  local i=0 c
  while [ $i -lt ${WAIT_MAX:-1200} ]; do
    c=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'shop/%' AND encryption_scheme=1 AND rotating_or_flushing=0" 2>/dev/null)
    if [ "$c" = 6 ]; then echo "all six shop tables are encrypted"; return 0; fi
    sleep ${WAIT_STEP:-10}
    i=$((i+${WAIT_STEP:-10}))
  done
  echo "the shop tables are still not all encrypted after 20 minutes"
  return 1
}

encrypt_tables(){ sudo mariadb < sql/encrypt_tables.sql; }

if [ -z "$DRY_RUN" ]; then
  sudo -v
  ( while true; do sudo -v; sleep 60; done ) &
  KEEP=$!
  trap 'pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null' EXIT
fi

echo "started $(date), results go to results/$NAME/" | tee -a $LOG
run "install packages, start Vault, create keys, load the data" bash scripts/setup.sh
run "attacker view before encryption" bash scripts/attack_view.sh unencrypted $NAME
run "shop queries before encryption" bash scripts/shop_bench.sh unencrypted $NAME
run "sysbench before encryption" bash scripts/bench.sh unencrypted $NAME
run "turn on encryption and the Vault key plugin" bash scripts/enable_encryption.sh
run "encrypt the six shop tables" encrypt_tables
run "wait until all shop tables are encrypted" wait_encrypted
run "check the setup" bash scripts/verify.sh
run "attacker view after encryption" bash scripts/attack_view.sh encrypted $NAME
run "shop queries after encryption" bash scripts/shop_bench.sh encrypted $NAME
run "sysbench after encryption" bash scripts/bench.sh encrypted $NAME
if [ -f scripts/rotate.sh ]; then
  run "key rotation under load" bash scripts/rotate.sh $NAME
else
  n=$((n+1))
  echo "[$n/$STEPS] key rotation: scripts/rotate.sh not found, skipped" | tee -a $LOG
fi
echo "finished $(date). Results are in results/$NAME/" | tee -a $LOG
