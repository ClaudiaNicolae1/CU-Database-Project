#!/bin/bash
# usage: bash scripts/compare.sh   (from the repo root)
tps(){ grep -h 'transactions:' "$@" 2>/dev/null | sed 's/.*(\(.*\) per sec.*/\1/' | awk '{s+=$1} END {if(NR) printf "%.0f",s/NR}'; }
p95(){ grep -h '95th percentile' "$@" 2>/dev/null | awk '{s+=$3} END {if(NR) printf "%.2f",s/NR}'; }
slap(){ grep -h 'Average number of seconds' "$@" 2>/dev/null | head -1 | awk '{print $(NF-1)}'; }
chg(){ if [ -n "$1" ] && [ -n "$2" ]; then awk -v a=$1 -v b=$2 'BEGIN{printf "%+.0f%%",(b-a)/a*100}'; else echo "-"; fi; }
d(){ echo "${1:--}"; }

echo "| Person | tps unencrypted | tps encrypted | change | p95 ms unencrypted | p95 ms encrypted | change | shop s unencrypted | shop s encrypted | change |"
echo "|---|---|---|---|---|---|---|---|---|---|"
for dir in results/*/; do
  n=$(basename $dir)
  tu=$(tps $dir/unencrypted_run*.txt); te=$(tps $dir/encrypted_run*.txt)
  pu=$(p95 $dir/unencrypted_run*.txt); pe=$(p95 $dir/encrypted_run*.txt)
  su=$(slap $dir/shop_unencrypted.txt); se=$(slap $dir/shop_encrypted.txt)
  echo "| $n | $(d $tu) | $(d $te) | $(chg $tu $te) | $(d $pu) | $(d $pe) | $(chg $pu $pe) | $(d $su) | $(d $se) | $(chg $su $se) |"
done
