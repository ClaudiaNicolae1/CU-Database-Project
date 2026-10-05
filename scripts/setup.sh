#!/bin/bash
# Installs MariaDB, Vault (dev mode), the Vault plugin, the key, and the dataset
set -e
sudo apt update
sudo apt install -y git xxd binutils sysbench openssl curl docker.io \
  mariadb-server mariadb-client mariadb-plugin-hashicorp-key-management
sudo systemctl enable --now docker mariadb
sudo docker start vault 2>/dev/null || sudo docker run -d --name vault \
  --cap-add=IPC_LOCK -p 8200:8200 -e VAULT_DEV_ROOT_TOKEN_ID=root hashicorp/vault
until curl -s http://127.0.0.1:8200/v1/sys/health >/dev/null; do sleep 1; done
V="sudo docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault"
$V secrets enable -path=mariadb -version=2 kv || true
$V kv get mariadb/1 >/dev/null 2>&1 || $V kv put mariadb/1 data=$(openssl rand -hex 32)
[ -d ~/test_db ] || git clone https://github.com/datacharmer/test_db.git ~/test_db
cd ~/test_db && sudo mariadb < employees.sql
echo "Setup done. Data is loaded and still unencrypted."
