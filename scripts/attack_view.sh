#!/bin/bash
# usage: bash scripts/attack_view.sh unencrypted|encrypted yourname
LABEL=$1
WHO=${2:-$USER}
mkdir -p results/$WHO
EMAIL=$(sudo mariadb -N -e "SELECT email FROM shop.users WHERE user_id=1")
NAME=$(sudo mariadb -N -e "SELECT full_name FROM shop.users WHERE user_id=1")
sudo mariadb -e "FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES;"
F=/var/lib/mysql/shop/users.ibd
{
  echo "== $LABEL: matches for email $EMAIL: $(sudo strings $F | grep -c "$EMAIL")"
  echo "== $LABEL: matches for name $NAME: $(sudo strings $F | grep -c "$NAME")"
  sudo strings $F | grep -m3 "@example.com"
  sudo xxd -s $((16384*10)) -l 128 $F
} | tee results/$WHO/attack_$LABEL.txt
