#!/bin/bash
# usage: bash scripts/extra/integrity_check.sh unencrypted|encrypted yourname
# Checks the shop database and records its size: CHECK TABLE on all six tables, row counts, foreign key
# orphans, table and file sizes. In the encrypted state it also checks that a new row and a new table
# created without an ENCRYPTED option end up encrypted. Output: results/NAME/integrity_LABEL.txt
set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
LABEL=$1
WHO=${2:-$USER}
case "$LABEL" in unencrypted|encrypted) ;; *) echo "usage: bash scripts/extra/integrity_check.sh unencrypted|encrypted yourname"; exit 2;; esac
mkdir -p results/$WHO
OUT=results/$WHO/integrity_$LABEL.txt
fail=0
q(){ sudo mariadb -N -e "$1" 2>&1; }
line(){ echo "$1" | tee -a $OUT; }
: > $OUT
line "== integrity check, $LABEL, $(date)"
line "== CHECK TABLE (expect status OK for all six)"
for t in users addresses payment_methods products orders order_items; do
  r=$(q "CHECK TABLE shop.$t" | awk '{print $NF}' | tail -1)
  line "$t: $r"; [ "$r" = OK ] || fail=1
done
line "== row counts"
for t in users addresses payment_methods products orders order_items; do line "$t: $(q "SELECT COUNT(*) FROM shop.$t")"; done
line "== foreign key orphans (expect 0 everywhere)"
for pair in "addresses user_id users user_id" "payment_methods user_id users user_id" "orders user_id users user_id" "order_items order_id orders order_id" "order_items product_id products product_id"; do
  set -- $pair
  n=$(q "SELECT COUNT(*) FROM shop.$1 c LEFT JOIN shop.$3 p ON c.$2=p.$4 WHERE p.$4 IS NULL")
  line "$1.$2 without a parent in $3: $n"; [ "$n" = 0 ] || fail=1
done
line "== encryption state of the six tables (scheme, key id, min and current key version)"
q "SELECT name, encryption_scheme, current_key_id, min_key_version, current_key_version FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'shop/%' ORDER BY name" | tee -a $OUT
line "== sizes: data+index bytes from information_schema, and the .ibd file size on disk"
for t in users addresses payment_methods products orders order_items; do
  b=$(q "SELECT data_length+index_length FROM information_schema.TABLES WHERE table_schema='shop' AND table_name='$t'")
  f=$(sudo stat -c %s /var/lib/mysql/shop/$t.ibd 2>/dev/null)
  line "$t: data+index=$b file=$f"
done
line "total shop/*.ibd on disk: $(sudo du -cb /var/lib/mysql/shop/*.ibd 2>/dev/null | tail -1 | awk '{print $1}') bytes"
if [ "$LABEL" = encrypted ]; then
  M="integritycheck$(date +%s)marker"
  line "== new row: insert a row with the unique text $M into users, flush, and search the raw file (expect 0)"
  q "INSERT INTO shop.users (user_id, full_name, email, phone, birth_date, national_id) SELECT 900000001, '$M', '$M@example.com', '0', birth_date, '$M' FROM shop.users WHERE user_id=1" >/dev/null
  n=$(q "SELECT COUNT(*) FROM shop.users WHERE user_id=900000001")
  if [ "$n" = 1 ]; then
    q "FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES" >/dev/null
    c=$(sudo strings /var/lib/mysql/shop/users.ibd | grep -c -F "$M")
    line "matches of the new text in users.ibd: $c"; [ "$c" = 0 ] || fail=1
    q "DELETE FROM shop.users WHERE user_id=900000001" >/dev/null
  else
    line "could not insert the test row (is the users schema different?): $n"; fail=1
  fi
  line "== new table without an ENCRYPTED option (expect encryption_scheme 1 and the default key id)"
  q "DROP TABLE IF EXISTS shop.t_default_test; CREATE TABLE shop.t_default_test (id INT PRIMARY KEY, s VARCHAR(100)) ENGINE=InnoDB; INSERT INTO shop.t_default_test VALUES (1,'$M')" >/dev/null
  r=$(q "SELECT encryption_scheme, current_key_id FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name='shop/t_default_test'" | tr '\t' ' ')
  line "t_default_test: scheme and key id = ${r:-not listed}"; [ "${r%% *}" = 1 ] || fail=1
  line "innodb_default_encryption_key_id = $(q "SELECT @@innodb_default_encryption_key_id")"
  line "== new table with ENCRYPTED=NO while innodb_encrypt_tables=ON (allowed unless FORCE; shows whether a table can opt out)"
  r=$(q "DROP TABLE IF EXISTS shop.t_plain_test; CREATE TABLE shop.t_plain_test (id INT PRIMARY KEY) ENGINE=InnoDB ENCRYPTED=NO" | head -1)
  line "CREATE ... ENCRYPTED=NO: ${r:-created}"
  r=$(q "SELECT encryption_scheme FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name='shop/t_plain_test'")
  line "t_plain_test: encryption_scheme = ${r:-not listed (unencrypted tables are not always listed)}"
  q "DROP TABLE IF EXISTS shop.t_default_test, shop.t_plain_test" >/dev/null
fi
if [ $fail = 0 ]; then line "== RESULT: all checks passed"; else line "== RESULT: SOME CHECKS FAILED"; exit 1; fi
