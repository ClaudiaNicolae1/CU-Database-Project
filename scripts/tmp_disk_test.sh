#!/bin/bash
# Usage: bash scripts/tmp_disk_test.sh (yourname)
# Shows whether internal on-disk temporary tables leak query data when
# encrypt_tmp_disk_tables is OFF vs ON.
set -e
cd "$(dirname "$0")/.." || exit 1
WHO=${1:-$USER}
sudo -v
mkdir -p results/$WHO
OUT=results/$WHO/tmp_disk_test.txt
TAG=TMPMARKER-$(date +%s)

run_case() {
  MODE=$1
  LABEL=$2
  bash scripts/enable_binlog_aria.sh "$MODE" > /dev/null
  PID=$(pidof mariadbd | awk '{print $1}')
  TMPDIR_PROC="/proc/$PID/root$(sudo mariadb -N -e 'SELECT @@tmpdir;')"

  echo "-- $LABEL (encrypt_tmp_disk_tables=$(sudo mariadb -N -e "SELECT @@encrypt_tmp_disk_tables;"))"
  sudo mariadb -e "
    SET SESSION tmp_table_size = 1024;
    SET SESSION max_heap_table_size = 1024;
    SELECT * FROM (
      SELECT CONCAT('$TAG', '-', phone) AS marker_val
      FROM shop.users
      GROUP BY marker_val
    ) t
    WHERE SLEEP(2) = 0
    LIMIT 1;
  " > /dev/null &
  QPID=$!

  FOUND=""
  for _ in $(seq 1 30); do
    if sudo sh -c "strings '$TMPDIR_PROC'/#sql* 2>/dev/null | grep -m 1 '$TAG'" > /tmp/tmp_hit.txt 2>/dev/null; then
      FOUND=$(cat /tmp/tmp_hit.txt)
      break
    fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.2
  done
  wait $QPID 2>/dev/null || true
  sudo rm -f /tmp/tmp_hit.txt

  if [ -n "$FOUND" ]; then
    echo "   LEAKED IN TEMP FILE: $FOUND"
  else
    echo "   (not found in plain text)"
  fi
}

{
  echo "### marker: $TAG"
  run_case plain "temporary disk table NOT encrypted"
  run_case encrypted "temporary disk table encrypted"
} | tee "$OUT"
