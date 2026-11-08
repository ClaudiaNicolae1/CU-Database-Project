#!/bin/bash
# usage: bash scripts/extra/rotation_probe.sh control|rotate TAG [NAME]
# Runs scripts/rotate_under_load.sh (control = the same load without key writes) and, at the same time,
# samples signals that could explain a change in throughput: CPU clock speed, temperature, Vault request
# lines, server CPU time, CPU idle and iowait (vmstat), and InnoDB's encryption counters.
# Results go to results/NAME/probe/TAG/ and results/NAME/probe/TAG_*.
set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
MODE=$1
TAG=$2
NAME=${3:-$USER}
case "$MODE" in control|rotate) ;; *) echo "usage: bash scripts/extra/rotation_probe.sh control|rotate TAG [NAME]"; exit 2;; esac
[ -n "$TAG" ] || { echo "usage: bash scripts/extra/rotation_probe.sh control|rotate TAG [NAME]"; exit 2; }
D=results/$NAME/probe
mkdir -p $D
S=$D/${TAG}_samples.tsv
ST=$D/${TAG}_status.tsv
VM=$D/${TAG}_vmstat.txt
VAULT="sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault"

sudo -v || exit 1
( while true; do sudo -v; sleep 60; done ) &
KEEP=$!
SPID=""
VPID=""
cleanup(){ kill $SPID $VPID $KEEP 2>/dev/null; $VAULT audit disable file/ >/dev/null 2>&1; }
trap cleanup EXIT

$VAULT audit enable file file_path=stdout >/dev/null 2>&1
printf 'time\tmhz\ttemp_c\tvault_log_lines\tserver_cpu_s\n' > $S
: > $ST
vmstat -t 5 > $VM &
VPID=$!
sampler(){
  local now mhz temp vl cpu pid
  while true; do
    now=$(date +%T)
    mhz=$(awk '/^cpu MHz/ {s+=$4; n++} END {if(n) printf "%.0f", s/n}' /proc/cpuinfo)
    temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
    temp=$(( ${temp:-0} / 1000 ))
    vl=$(sudo docker logs vault 2>&1 | wc -l)
    pid=$(pidof mariadbd | awk '{print $1}')
    cpu=$(awk '{printf "%.1f", ($14+$15)/100}' /proc/$pid/stat 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$mhz" "$temp" "$vl" "$cpu" >> $S
    sudo mariadb -N -e "SELECT variable_name, variable_value FROM information_schema.GLOBAL_STATUS WHERE variable_name LIKE 'INNODB_ENCRYPTION%'" 2>/dev/null | awk -v t=$now '{print t"\t"$1"\t"$2}' >> $ST
    sleep 5
  done
}
sampler &
SPID=$!
if [ $MODE = control ]; then
  V2=9999 V3=9999 bash scripts/rotate_under_load.sh $NAME/probe/$TAG
else
  bash scripts/rotate_under_load.sh $NAME/probe/$TAG
fi
rc=$?
echo "probe $MODE $TAG finished with exit code $rc, files in $D"
exit $rc
