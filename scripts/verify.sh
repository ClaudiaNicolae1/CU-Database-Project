#!/bin/bash
# usage: bash scripts/verify.sh
# Checks that the running setup is what the README says. Exit code 0 = all passed.
fail=0
ok(){ echo "PASS  $1"; }
bad(){ echo "FAIL  $1"; fail=1; }
q(){ sudo mariadb -N -e "$1" 2>/dev/null; }

[ "$(q "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='hashicorp_key_management'")" = ACTIVE ] && ok "Vault key plugin is active" || bad "Vault key plugin is not active"

v=$(q "SHOW VARIABLES LIKE 'innodb_encrypt_tables'" | awk '{print $2}')
[ "$v" = ON ] || [ "$v" = FORCE ] && ok "innodb_encrypt_tables = $v" || bad "innodb_encrypt_tables = $v"
v=$(q "SHOW VARIABLES LIKE 'innodb_encrypt_log'" | awk '{print $2}')
[ "$v" = ON ] && ok "innodb_encrypt_log = ON" || bad "innodb_encrypt_log = $v"

for pair in users:2 addresses:2 payment_methods:2 products:1 orders:1 order_items:1; do
  t=${pair%%:*}
  k=${pair##*:}
  got=$(q "SELECT CONCAT(encryption_scheme,'/',current_key_id,'/',rotating_or_flushing) FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name='shop/$t'")
  [ "$got" = "1/$k/0" ] && ok "shop.$t is encrypted with key $k" || bad "shop.$t expected 1/$k/0 (scheme/key/rotating), got '$got'"
done

n=$(q "SELECT COUNT(*) FROM shop.users")
[ "$n" = 200000 ] && ok "shop.users has 200000 rows" || bad "shop.users has '$n' rows, README says 200000"
n=$(q "SELECT COUNT(*) FROM shop.orders")
[ "$n" = 1000000 ] && ok "shop.orders has 1000000 rows" || bad "shop.orders has '$n' rows, README says 1000000"

name=$(q "SELECT full_name FROM shop.users WHERE user_id=1")
sudo mariadb -e "FLUSH TABLES shop.users FOR EXPORT; UNLOCK TABLES;" 2>/dev/null
c=$(sudo strings /var/lib/mysql/shop/users.ibd 2>/dev/null | grep -c "$name")
[ "$c" = 0 ] && ok "name of user 1 not found in the raw users.ibd" || bad "name of user 1 found $c times in the raw users.ibd"

for id in 1 2; do
  sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault kv get mariadb/$id > /dev/null 2>&1 && ok "key $id exists in Vault" || bad "key $id missing in Vault"
done
grep -q "^hashicorp-key-management-cache-version-timeout" /etc/mysql/mariadb.conf.d/60-encryption.cnf && ok "cache-version-timeout is set" || bad "cache-version-timeout is not set"

[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
