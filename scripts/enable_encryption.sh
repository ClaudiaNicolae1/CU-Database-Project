#!/bin/bash
# Turns on encryption at rest with the Vault key manager
set -e
sudo tee /etc/mysql/mariadb.conf.d/60-encryption.cnf > /dev/null << 'CNF'
[mariadb]
plugin_load_add = hashicorp_key_management
hashicorp-key-management-vault-url = http://127.0.0.1:8200/v1/mariadb
hashicorp-key-management-token = root
hashicorp-key-management-cache-version-timeout = 60000
innodb_encrypt_tables = ON
innodb_encrypt_log = ON
innodb_encryption_threads = 4
encrypt_tmp_files = ON
CNF
sudo systemctl restart mariadb
echo "Encryption enabled. Check progress with INNODB_TABLESPACES_ENCRYPTION."
