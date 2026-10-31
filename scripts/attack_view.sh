#!/bin/bash
# usage: bash scripts/attack_view.sh unencrypted|encrypted yourname
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
{
  echo "== $LABEL: matches for email $EMAIL: $(sudo strings $F | grep -c "$EMAIL")"
  echo "== $LABEL: matches for name $NAME: $(sudo strings $F | grep -c "$NAME")"
  sudo strings $F | grep -m3 "@example.com"
  sudo xxd -s $((16384*10)) -l 128 $F
} | tee results/$WHO/attack_$LABEL.txt
rc=$?
if [ $rc != 0 ]; then
  echo "attack_view.sh: failed with exit code $rc, no result saved"
  rm -f results/$WHO/attack_$LABEL.txt
  exit $rc
fi
