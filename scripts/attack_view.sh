#!/bin/bash
# usage: bash scripts/attack_view.sh unencrypted|encrypted yourname
# Looks at the raw data file of shop.users the way someone with only the files would.
# unencrypted: finds where the email of user 1 sits in the file and prints the bytes around it.
# encrypted:   prints the bytes at the same place (the offset is read from the unencrypted result).
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
LABEL=$1
WHO=${2:-$USER}
case "$LABEL" in unencrypted|encrypted) ;; *) echo "usage: bash scripts/attack_view.sh unencrypted|encrypted yourname"; exit 2;; esac
mkdir -p results/$WHO
EMAIL=$(sudo mariadb -N -e "SELECT email FROM shop.users WHERE user_id=1")
NAME=$(sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1")
if [ -z "$EMAIL" ] || [ -z "$NAME" ]; then
  echo "attack_view.sh: could not read user 1 from shop.users (is MariaDB running?)"
  exit 1
fi
sudo mariadb -e "FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES;" || { echo "attack_view.sh: could not flush shop.users"; exit 1; }
F=/var/lib/mysql/shop/users.ibd
sudo test -f $F || { echo "attack_view.sh: $F not found"; exit 1; }
REF=results/$WHO/attack_unencrypted.txt
NOTE=""
if [ "$LABEL" = unencrypted ]; then
  OFF=$(sudo strings -t d $F | grep -m1 -F "$EMAIL" | awk '{print $1}')
  [ -n "$OFF" ] || { echo "attack_view.sh: the email of user 1 is not in $F, so this is not an unencrypted file"; exit 1; }
else
  OFF=$(grep -m1 '^== reference offset' $REF 2>/dev/null | awk '{print $5}')
  if [ -z "$OFF" ]; then
    OFF=$((16384*10))
    NOTE="(no reference offset in $REF, so page 10 is shown instead)"
  fi
fi
START=$((OFF-48))
[ $START -lt 0 ] && START=0
{
  echo "== $LABEL: matches for email $EMAIL: $(sudo strings $F | grep -c -F "$EMAIL")  (the email belongs to user 1 only)"
  echo "== $LABEL: matches for name $NAME: $(sudo strings $F | grep -c -F "$NAME")  (rows that share this name, because the generated names repeat)"
  if [ "$LABEL" = unencrypted ]; then
    echo "== reference offset (bytes): $OFF (page $((OFF/16384)), $((OFF%16384)) bytes into the page)"
    sudo strings $F | grep -m3 -F "@example.com"
  else
    echo "== $LABEL: the bytes at the same place as the unencrypted run: offset $OFF $NOTE"
  fi
  echo "== 128 bytes from offset $START"
  sudo xxd -s $START -l 128 $F
} | tee results/$WHO/attack_$LABEL.txt
rc=$?
if [ $rc != 0 ]; then
  echo "attack_view.sh: failed with exit code $rc, no result saved"
  rm -f results/$WHO/attack_$LABEL.txt
  exit $rc
fi
