#!/bin/bash
# usage: bash scripts/stats.sh yourname
# Mean and sample standard deviation over the three sysbench runs of each state, plus read-only and write-only latency if present.
cd "$(dirname "$0")/.." || exit 1
WHO=${1:-$USER}
D=results/$WHO
[ -d $D ] || { echo "stats.sh: no folder $D"; exit 1; }
stat(){ awk -v name="$1" '{s+=$1; ss+=$1*$1; n++} END { if(n<1){print name": no runs"; exit} m=s/n; v=(n>1)?(ss-n*m*m)/(n-1):0; if(v<0)v=0; sd=sqrt(v); printf "%s: n=%d mean=%.1f sd=%.1f (%.1f%%)\n", name, n, m, sd, (m?sd/m*100:0) }'; }
echo "== $WHO: sysbench oltp_read_write, per state"
for st in unencrypted encrypted; do
  ls $D/${st}_run*.txt >/dev/null 2>&1 || continue
  grep -h 'transactions:' $D/${st}_run*.txt | sed -E 's/.*\(([0-9.]+) per sec.*/\1/' | stat "$st tps"
  grep -h '95th percentile' $D/${st}_run*.txt | awk '{print $NF}' | stat "$st p95 ms"
  grep -h ' avg:' $D/${st}_run*.txt | awk '{print $NF}' | stat "$st avg latency ms"
done
for st in unencrypted encrypted; do
  for m in readonly writeonly; do
    f=$D/${st}_$m.txt; [ -f $f ] || continue
    printf "%s %s: tps=%s avg=%s ms p95=%s ms\n" "$st" "$m" "$(grep 'transactions:' $f | sed -E 's/.*\(([0-9.]+) per sec.*/\1/')" "$(grep ' avg:' $f | awk '{print $NF}')" "$(grep '95th percentile' $f | awk '{print $NF}')"
  done
done
for st in unencrypted encrypted; do
  f=$D/${st}_resources.txt; [ -f $f ] || continue
  echo "== $st resources (from bench.sh): $(cat $f | tr '\n' '; ')"
done
