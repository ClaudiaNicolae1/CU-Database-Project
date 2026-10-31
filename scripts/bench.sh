#!/bin/bash
# usage: bash scripts/bench.sh unencrypted|encrypted yourname
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
LABEL=$1
WHO=${2:-$USER}
case "$LABEL" in unencrypted|encrypted) ;; *) echo "usage: bash scripts/bench.sh unencrypted|encrypted yourname"; exit 2;; esac
mkdir -p results/$WHO
SB="--mysql-socket=/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest --mysql-db=sbtest --tables=8 --table-size=500000"
ENC="SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'sbtest/%' AND encryption_scheme=1"

sudo mariadb -e "CREATE DATABASE IF NOT EXISTS sbtest; CREATE USER IF NOT EXISTS 'sbtest'@'localhost' IDENTIFIED BY 'sbtest'; GRANT ALL ON sbtest.* TO 'sbtest'@'localhost';" || { echo "bench.sh: could not create the sbtest database and user"; exit 1; }

if [ "$LABEL" = unencrypted ]; then
  e=$(sudo mariadb -N -e "$ENC" 2>/dev/null)
  if [ "${e:-0}" != 0 ]; then
    echo "bench.sh: $e sbtest tables are already encrypted, so this would not be an unencrypted baseline."
    echo "Decrypt them first (ALTER TABLE sbtest.sbtestN ENCRYPTED=NO for N=1..8) or use a fresh machine."
    exit 1
  fi
fi

if [ -z "$(sudo mariadb -N -e "SHOW TABLES FROM sbtest LIKE 'sbtest1'")" ]; then
  sysbench oltp_read_write $SB prepare || { echo "bench.sh: sysbench prepare failed"; exit 1; }
fi

if [ "$LABEL" = encrypted ]; then
  echo "waiting for the sbtest tables to be encrypted..."
  waited=0
  while true; do
    n=$(sudo mariadb -N -e "$ENC AND rotating_or_flushing=0" 2>/dev/null)
    echo "[$(date +%T)] encrypted sbtest tables: ${n:-0} of 8"
    [ "$n" = 8 ] && break
    if [ $waited -ge ${WAIT_MAX:-1800} ]; then
      echo "bench.sh: the sbtest tables are still not all encrypted after ${WAIT_MAX:-1800} s"
      exit 1
    fi
    sleep ${WAIT_STEP:-10}
    waited=$((waited+${WAIT_STEP:-10}))
  done
fi

for i in 1 2 3; do
  sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run | tee results/$WHO/${LABEL}_run$i.txt
  rc=$?
  if [ $rc != 0 ]; then
    echo "bench.sh: sysbench run $i failed with exit code $rc, stopping"
    rm -f results/$WHO/${LABEL}_run$i.txt
    exit $rc
  fi
done
