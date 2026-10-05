#!/bin/bash
set -e
cd "$(dirname "$0")/.."
sudo mariadb < sql/schema.sql
mkdir -p data
g++ -O2 -o data/generate_data scripts/generate_data.cpp
./data/generate_data
sudo mariadb -e "SET GLOBAL local_infile=1;"
for t in users addresses payment_methods products orders order_items; do
  echo "loading $t"
  sudo mariadb --local-infile=1 -e "SET foreign_key_checks=0; SET unique_checks=0; LOAD DATA LOCAL INFILE 'data/$t.csv' INTO TABLE shop.$t FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"' LINES TERMINATED BY '\n';"
done
