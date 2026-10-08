# Encryption at rest and key management in MariaDB

Authors: Mercedes Dager, Claudia Nicolae, Francisco Silva, Daris Naska

We encrypt a database with MariaDB table encryption, keep the keys in HashiCorp Vault, rotate a key while the server is serving traffic, measure the performance cost and look at what someone with only the data files can see.

## What is in the repo

- `scripts/`: setup, attacker view, benchmarks, key rotation
- `sql/`: schema of the test database (`shop`) and the statements that encrypt it
- `results/<name>/`: raw outputs, one folder per person

## Setup (Ubuntu 24.04)

```bash
git clone https://github.com/ClaudiaNicolae1/CU-Database-Project.git
cd CU-Database-Project
bash scripts/setup.sh
bash scripts/attack_view.sh unencrypted NAME
bash scripts/shop_bench.sh unencrypted NAME
bash scripts/bench.sh unencrypted NAME
bash scripts/enable_encryption.sh
sudo mariadb < sql/encrypt_tables.sql
sudo mariadb -e "SELECT name, current_key_id, rotating_or_flushing FROM information_schema.INNODB_TABLESPACES_ENCRYPTION WHERE name LIKE 'shop/%';"
bash scripts/attack_view.sh encrypted NAME
bash scripts/shop_bench.sh encrypted NAME
bash scripts/bench.sh encrypted NAME
bash scripts/rotate.sh NAME
```

Use your own name instead of `NAME`. Before the encrypted steps, wait until `rotating_or_flushing` is 0 for every row of the query above.

Vault runs in Docker in dev mode with the token `root`. This is for the project only. Dev mode keeps keys in memory so removing the container makes the encrypted tables unreadable.

## Findings: one Vault plugin setting caused a ~15x slowdown

With the default settings on MariaDB 10.11.14, encrypted throughput fell by 93%. Setting one option brought it back to within about 9% of unencrypted.

Test machine: Lenovo ThinkPad T16 Gen 4, Intel(R) Core(TM) Ultra 5 225U
, 14 threads, 32 GB, Ubuntu 24.04, MariaDB 10.11.14, sysbench 1.0.20. Numbers from other machines will differ.

sysbench `oltp_read_write`, 8 threads, 60 s, average of 3 runs (files in `results/claudia/`):

| Configuration | Transactions/s | p95 latency (ms) |
|---|---|---|
| Unencrypted | 2661 | 4.74 |
| Encrypted, default plugin settings | 179 | 272.6 |
| Encrypted, `cache-version-timeout=60000` | 2423 | 6.30 |

What we found:

- **Not the cipher:** the CPU has hardware AES, it was 86 to 87% idle and disk wait was 0 to 2% during the slow phase.
- **Not the redo log:** switching off redo log encryption changed nothing (about 194 to 207 tps).
- **The Vault plugin:** `hashicorp-key-management-cache-version-timeout` defaults to 0 in this version, so the latest key version is looked up in Vault again and again. With Vault's audit log on, a 20 s run produced about 30,600 audit lines (roughly 750 requests per second, assuming about two lines per request). After setting the timeout to 60000 ms, two 60 s runs produced 10 and 26 lines. According to the MariaDB documentation, the default became 60 s in 10.11.15.

The fix is one line in `scripts/enable_encryption.sh`:

```
hashicorp-key-management-cache-version-timeout = 60000
```

Files: `results/claudia/encrypted_defaultcache_run*.txt` (before the fix) and `encrypted_run*.txt` (after).

### How the cause was found

```bash
SB="--mysql-socket=/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest --mysql-db=sbtest --tables=8 --table-size=500000"
```

**1. Is it the cipher?** Check that the CPU has AES instructions and watch CPU and disk during an encrypted run (`id` is CPU idle %, `wa` is disk wait %):

```bash
grep -m1 -o aes /proc/cpuinfo
vmstat 10 6 > /tmp/vm.txt &
sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run
wait
cat /tmp/vm.txt
```

Result: `aes` was present. In the `vmstat` output the first row is an average since boot and is ignored. CPU idle was 70% in the first 10 s, while throughput was still high, then 86 to 87%. Disk wait was 0 to 2%.

**2. Is it the redo log?** Turn off redo log encryption, restart and run twice:

```bash
sudo sed -i 's/innodb_encrypt_log = ON/innodb_encrypt_log = OFF/' /etc/mysql/mariadb.conf.d/60-encryption.cnf
sudo systemctl restart mariadb
for i in 1 2; do sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run; done
```

Result: 194 and 207 tps, the same as with it on. It stayed off for the first part of step 3.

**3. Is it the Vault plugin?** Turn on Vault's audit log and count its lines around a run:

```bash
v() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault "$@"; }
v audit enable file file_path=stdout
docker logs vault 2>&1 | wc -l
sysbench oltp_read_write $SB --threads=8 --time=20 run
docker logs vault 2>&1 | wc -l
```

Result with the default settings (redo log encryption still off for this run): about 30,600 new audit lines in 20 s. Then turn redo log encryption back on, set the cache option, restart, and count around two 60 s runs:

```bash
sudo sed -i 's/innodb_encrypt_log = OFF/innodb_encrypt_log = ON/' /etc/mysql/mariadb.conf.d/60-encryption.cnf
echo "hashicorp-key-management-cache-version-timeout = 60000" | sudo tee -a /etc/mysql/mariadb.conf.d/60-encryption.cnf
sudo systemctl restart mariadb
for i in 1 2; do
  docker logs vault 2>&1 | wc -l
  sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run
  docker logs vault 2>&1 | wc -l
done
v audit disable file/
```

Result: 10 and 26 new lines in the two runs and throughput back to about 2400 tps. The restart between the measurements produced about 9,700 audit lines, which are outside the benchmark windows. InnoDB's own `keyserver_requests` counter did not change during a slow run (19 before and after) so it does not show these lookups. The audit log did.

The option and its default are described in the [MariaDB documentation](https://mariadb.com/docs/server/security/encryption/data-at-rest-encryption/key-management-and-encryption-plugins/hashicorp-key-management-plugin).

## Still to document

- Key rotation under load: TODO (`scripts/rotate.sh`)
- What the data files show before and after encryption: TODO (`results/<name>/attack_*.txt`)
- What happens when Vault is unavailable: TODO

## Limits

One machine per person, three runs per configuration and about 10% variation between runs. Absolute numbers depend on the machine.
