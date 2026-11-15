#!/bin/bash
# Usage: bash scripts/attack_binlog_aria.sh plain|encrypted
# Looks for the text "MARCA" in the raw files a thief could copy.
cd "$(dirname "$0")/.." || exit 1
MODE=${1:?usage: $0 plain|encrypted yourname}
WHO=${2:-$USER}
sudo -v
DATADIR=$(sudo mariadb -N -e "SELECT @@datadir;")
mkdir -p results/$WHO
OUT=results/$WHO/attack_binlog_aria_$MODE.txt

{
  echo "### mode: $MODE   datadir: $DATADIR"
  sudo find "$DATADIR" -maxdepth 2 \
    \( -name 'mariadb-bin.0*' -o -name 'aria_test*.MAD' -o -name 'aria_log.0*' \) \
    -not -name '*.idx' | sort |
  while read -r f; do
    echo "== $f"
    sudo strings "$f" | grep MARCA || echo "   (no aparece)"
  done
} | tee "$OUT"
