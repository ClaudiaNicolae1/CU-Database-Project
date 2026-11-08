#!/bin/bash
# usage: bash scripts/run_all.sh yourname
# Runs every step of the project in order on a fresh Ubuntu 24.04 machine and stops at the first failure.
# It takes about an hour: the data load alone takes 10 to 20 minutes, sysbench prepares 8 x 500,000 rows
# and runs six timed minutes, and the encryption steps wait for InnoDB to finish.
# DRY_RUN=1 bash scripts/run_all.sh yourname   prints the steps without running them.
# FORCE=1 bash scripts/run_all.sh yourname     skips the check for an already set up machine (the unencrypted numbers may then be wrong).
NAME=${1:-$USER}
cd "$(dirname "$0")/.." || exit 1
mkdir -p results/$NAME
LOG=results/$NAME/run_all.log
CNF=${CNF:-/etc/mysql/mariadb.conf.d/60-encryption.cnf}
STEPS=12
n=0
T0=$SECONDS

run(){
  n=$((n+1))
  echo "[$n/$STEPS] $1" | tee -a $LOG
  if [ -n "$DRY_RUN" ]; then return 0; fi
  shift
  "$@" 2>&1 | tee -a $LOG
  rc=${PIPESTATUS[0]}
  if [ $rc != 0 ]; then
    echo "STOPPED: step $n failed with exit code $rc after $(( (SECONDS-T0)/60 )) min. See $LOG" | tee -a $LOG
    exit $rc
  fi
}

wait_encrypted(){
  local i=0 c
  while true; do
    c=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'shop/%' AND encryption_scheme=1 AND rotating_or_flushing=0" 2>/dev/null)
    echo "[$(date +%T)] encrypted shop tables: ${c:-0} of 6"
    if [ "$c" = 6 ]; then echo "all six shop tables are encrypted"; return 0; fi
    if [ $i -ge ${WAIT_MAX:-1200} ]; then
      echo "the shop tables are still not all encrypted after ${WAIT_MAX:-1200} s"
      return 1
    fi
    sleep ${WAIT_STEP:-10}
    i=$((i+${WAIT_STEP:-10}))
  done
}

encrypt_tables(){ sudo mariadb < sql/encrypt_tables.sql; }

if [ -z "$DRY_RUN" ] && [ -z "$FORCE" ]; then
  if [ -f $CNF ]; then
    echo "STOP: $CNF exists, so this machine was already set up."
    echo "The unencrypted baseline would be measured on tables that are already encrypted. Use a fresh machine."
    echo "(FORCE=1 overrides this check, and the unencrypted numbers may then be wrong.)"
    exit 1
  fi
  e=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'sbtest/%' AND encryption_scheme=1" 2>/dev/null)
  if [ "${e:-0}" != 0 ]; then
    echo "STOP: $e sbtest tables are already encrypted, so the unencrypted baseline would be wrong. Use a fresh machine."
    echo "(FORCE=1 overrides this check.)"
    exit 1
  fi
fi

if [ -z "$DRY_RUN" ]; then
  sudo -v
  ( while true; do sudo -v; sleep 60; done ) &
  KEEP=$!
  trap 'pkill -P $KEEP 2>/dev/null; kill $KEEP 2>/dev/null' EXIT
fi

echo "started $(date), results go to results/$NAME/. This takes about an hour." | tee -a $LOG
run "install packages, start Vault, create keys, load the data" bash scripts/setup.sh
run "attacker view before encryption" bash scripts/attack_view.sh unencrypted $NAME
run "shop queries before encryption" bash scripts/shop_bench.sh unencrypted $NAME
run "sysbench before encryption (prepare, then 3 runs of 60 s)" bash scripts/bench.sh unencrypted $NAME
run "turn on encryption and the Vault key plugin" bash scripts/enable_encryption.sh
run "encrypt the six shop tables" encrypt_tables
run "wait until all shop tables are encrypted" wait_encrypted
run "check the setup" bash scripts/verify.sh
run "attacker view after encryption" bash scripts/attack_view.sh encrypted $NAME
run "shop queries after encryption" bash scripts/shop_bench.sh encrypted $NAME
run "sysbench after encryption (waits for sbtest, then 3 runs of 60 s)" bash scripts/bench.sh encrypted $NAME
ROT=scripts/rotate.sh
[ -f $ROT ] || ROT=scripts/rotate_under_load.sh
if [ -f $ROT ]; then
  run "key rotation under load" bash $ROT $NAME
else
  n=$((n+1))
  echo "[$n/$STEPS] key rotation: no rotation script found, skipped" | tee -a $LOG
fi
echo "finished $(date) after $(( (SECONDS-T0)/60 )) min. Results are in results/$NAME/" | tee -a $LOG
