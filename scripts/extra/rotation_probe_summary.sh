#!/bin/bash
# usage: bash scripts/extra/rotation_probe_summary.sh NAME TAG1 TAG2 ...
# Compares, for each run, the mean of every signal before and after the second key version (60 s into the run).
NAME=$1
shift
cd "$(dirname "$0")/../.." || exit 1
secs(){ awk -F: '{print $1*3600+$2*60+$3}'; }
ba(){ # file, column -> "before/after"; time column 1 is HH:MM:SS, START in $START
  awk -F'\t' -v start=$START -v col=$2 -v scale=${3:-1} 'function s(x,  a){split(x,a,":"); return a[1]*3600+a[2]*60+a[3]}
    NR>1 && $col!="" { t=s($1)-start; if(t>=5&&t<=55){sb+=$col;nb++} if(t>=65&&t<=225){sa+=$col;na++} }
    END { if(nb&&na) printf "%.1f/%.1f", sb/nb*scale, sa/na*scale; else printf "-" }' $1
}
delta(){ # per-second rate of a cumulative column
  awk -F'\t' -v start=$START -v col=$2 'function s(x,  a){split(x,a,":"); return a[1]*3600+a[2]*60+a[3]}
    NR>1 && $col!="" { t=s($1)-start; if(p!="" && t>pt){ r=($col-p)/(t-pt); if(t>=10&&t<=55){sb+=r;nb++} if(t>=70&&t<=225){sa+=r;na++} } p=$col; pt=t }
    END { if(nb&&na) printf "%.2f/%.2f", sb/nb, sa/na; else printf "-" }' $1
}
rounds(){ # type (scan|point): from the summary tables, before = 0-50 s, after = 60-220 s
  awk -v ty="$2" '$0 ~ "== " ty " workers" {on=1; next} /^total:/ {on=0} on && $1 ~ /^[0-9]+$/ { if($1<=50){sb+=$2;nb++} if($1>=60&&$1<=220){sa+=$2;na++} }
    END { if(nb&&na) printf "%.0f/%.0f", sb/nb, sa/na; else printf "-" }' $1
}
vmcol(){ # vmstat -t file, column name
  awk -v start=$START -v name=$2 'function s(x,  a){split(x,a,":"); return a[1]*3600+a[2]*60+a[3]}
    /swpd/ { for(i=1;i<=NF;i++) if($i==name) c=i; next }
    $1 ~ /^[0-9]+$/ && c { n++; if(n==1) next; t=s($NF)-start; v=$c; if(t>=5&&t<=55){sb+=v;nb++} if(t>=65&&t<=225){sa+=v;na++} }
    END { if(nb&&na) printf "%.0f/%.0f", sb/nb, sa/na; else printf "-" }' $1
}
printf '%-10s %-12s %-12s %-12s %-10s %-14s %-14s %-10s %-10s\n' tag scan/10s point/10s cpu_mhz temp_c vault_lines/s server_cpu_s/s idle% iowait%
echo "(each cell is: mean before the second key version / mean after it)"
for tag in "$@"; do
  d=results/$NAME/probe/$tag
  [ -f $d/rotation_events.txt ] || { echo "$tag: no results in $d"; continue; }
  START=$(head -1 $d/rotation_events.txt | awk '{print $2}' | tr -d ',' | secs)
  P=results/$NAME/probe
  printf '%-10s %-12s %-12s %-12s %-10s %-14s %-14s %-10s %-10s\n' $tag "$(rounds $d/rotation_summary.txt scan)" "$(rounds $d/rotation_summary.txt point)" "$(ba $P/${tag}_samples.tsv 2)" "$(ba $P/${tag}_samples.tsv 3)" "$(delta $P/${tag}_samples.tsv 4)" "$(delta $P/${tag}_samples.tsv 5)" "$(vmcol $P/${tag}_vmstat.txt id)" "$(vmcol $P/${tag}_vmstat.txt wa)"
done
echo
echo "InnoDB encryption counters that changed during each run (first -> last value):"
for tag in "$@"; do
  f=results/$NAME/probe/${tag}_status.tsv
  [ -s $f ] || continue
  echo "-- $tag"
  awk -F'\t' '{ if(!($2 in first)) first[$2]=$3; last[$2]=$3 } END { for(k in first) if(first[k]!=last[k]) printf "   %s: %s -> %s\n", k, first[k], last[k] }' $f | sort
done
