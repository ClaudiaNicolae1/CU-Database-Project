#!/bin/bash
# usage: bash scripts/bench.sh unencrypted|encrypted yourname
LABEL=$1
WHO=${2:-$USER}
mkdir -p results/$WHO
SB="--mysql-socket=/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest --mysql-db=sbtest --tables=8 --table-size=500000"
sudo mariadb -e "CREATE DATABASE IF NOT EXISTS sbtest; CREATE USER IF NOT EXISTS 'sbtest'@'localhost' IDENTIFIED BY 'sbtest'; GRANT ALL ON sbtest.* TO 'sbtest'@'localhost';"
if [ -z "$(sudo mariadb -N -e "SHOW TABLES FROM sbtest LIKE 'sbtest1'")" ]; then
  sysbench oltp_read_write $SB prepare
fi
if [ "$LABEL" = encrypted ]; then
  echo "waiting for the sbtest tables to be encrypted..."
  until [ "$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'sbtest/%' AND encryption_scheme=1 AND rotating_or_flushing=0")" = 8 ]; do
    sleep 5
  done
fi
for i in 1 2 3; do
  sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run | tee results/$WHO/${LABEL}_run$i.txt
done
