#!/bin/bash
# usage: bash scripts/extra/rw_bench.sh unencrypted|encrypted yourname
# Read-only and write-only sysbench runs (60 s each, 8 threads) on the sbtest tables that bench.sh prepared,
# so read latency and write latency can be compared separately. Output: results/NAME/LABEL_readonly.txt and LABEL_writeonly.txt
set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
LABEL=$1
WHO=${2:-$USER}
case "$LABEL" in unencrypted|encrypted) ;; *) echo "usage: bash scripts/extra/rw_bench.sh unencrypted|encrypted yourname"; exit 2;; esac
mkdir -p results/$WHO
SB="--mysql-socket=/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest --mysql-db=sbtest --tables=8 --table-size=500000"
[ -n "$(sudo mariadb -N -e "SHOW TABLES FROM sbtest LIKE 'sbtest1'" 2>/dev/null)" ] || { echo "rw_bench.sh: the sbtest tables do not exist; run scripts/bench.sh first"; exit 1; }
for mode in read_only write_only; do
  f=results/$WHO/${LABEL}_${mode/_/}.txt
  sysbench oltp_$mode $SB --threads=8 --time=60 --report-interval=10 run | tee $f
  rc=$?
  if [ $rc != 0 ]; then echo "rw_bench.sh: sysbench $mode failed with exit code $rc"; rm -f $f; exit $rc; fi
done
