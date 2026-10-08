#!/bin/bash
# usage: bash scripts/shop_bench.sh unencrypted|encrypted yourname
LABEL=$1
WHO=${2:-$USER}
mkdir -p results/$WHO
sudo mariadb-slap --create-schema=shop --query=sql/workload.sql --delimiter=";" --concurrency=4 --iterations=3 | tee results/$WHO/shop_$LABEL.txt
