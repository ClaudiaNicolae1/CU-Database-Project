#!/bin/bash
# usage: bash scripts/shop_bench.sh unencrypted|encrypted yourname
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
LABEL=$1
WHO=${2:-$USER}
case "$LABEL" in unencrypted|encrypted) ;; *) echo "usage: bash scripts/shop_bench.sh unencrypted|encrypted yourname"; exit 2;; esac
mkdir -p results/$WHO
OUT=results/$WHO/shop_$LABEL.txt
sudo mariadb-slap --create-schema=shop --query=sql/workload.sql --delimiter=";" --concurrency=4 --iterations=3 | tee $OUT
rc=$?
if [ $rc != 0 ]; then
  echo "shop_bench.sh: mariadb-slap failed with exit code $rc, no result saved"
  rm -f $OUT
  exit $rc
fi
if ! grep -q 'Average number of seconds' $OUT; then
  echo "shop_bench.sh: the output has no timing, no result saved"
  rm -f $OUT
  exit 1
fi
