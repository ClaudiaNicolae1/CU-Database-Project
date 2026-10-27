A project for area 10, "Encryption and key management" for the MariaDB student database projects, 2026-09. ([project page](https://mariadb.org/bachelor_hackathon_2026-09/))

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

Use your name instead of `NAME`. Before the encrypted steps, wait until `rotating_or_flushing` is 0 for every row of the query above.

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
  
  Outputs of the tests: `results/claudia/experiments/` (`debug_encrypted.txt`, `exp_logoff_run1.txt`, `exp_logoff_run2.txt`, `debug_vault_cache.txt`).

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

## What happens when the key manager is unavailable

Observed: after a reboot the Vault container was not running, so port 8200 refused connections. MariaDB then did not start at all. The error log shows the plugin failing its first request to Vault (`curl returned this error code: 7 ... Failed to connect to 127.0.0.1 port 8200`, `Unable to get storage options for ".../sys/mounts/mariadb/tune"`), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. Dev-mode Vault keeps its keys in memory, so starting the container again gives an empty Vault: the keys were gone and the encrypted data could not be read any more. The databases were rebuilt with `scripts/setup.sh`. Lines: `results/claudia/vault_stopped_at_startup.txt`.

Controlled test (`scripts/vault_down.sh`): the Vault container is paused, so it stops answering but keeps its keys in memory.

- **A, running server:** four workers read and update the `shop` tables for 240 s. Vault is paused from second 20 to second 170, and the duration and result of every round are logged.
- **B, restart:** MariaDB is restarted while Vault is paused. The service state and a test query are logged every 5 s. Then Vault is resumed, and the time until MariaDB answers again is recorded.

Both are run twice, with `hashicorp-key-management-use-cache-on-timeout` set to `off` and to `on`.

What the MariaDB documentation says about this version (10.11.14), to compare with the results:

- When Vault does not answer, the plugin waits `hashicorp-key-management-timeout` (15 s by default) per request and retries 3 times.
- `use-cache-on-timeout` is `OFF` by default here and covers only timeouts. From 10.11.16 it is `ON` by default and covers all errors, so a server keeps running on cached keys while Vault is temporarily unreachable.
- Keys and key versions are cached. In this version the cache times (including our `cache-version-timeout`) are measured in process CPU time, not wall-clock time. This was fixed in 10.11.19.
- The plugin does not unseal Vault by itself.

Results of the controlled test (MariaDB 10.11.14, run once with `use-cache-on-timeout` off and once on; the two runs gave the same picture):

- **A, running server, Vault paused for 150 s:** 41,661 rounds (off) and 41,983 rounds (on) of reads and updates, with 0 errors in both. The average round took 0.02 s and the slowest 0.03 s, and the rate during the pause (about 1,750 rounds per 10 s) was the same as before it. The MariaDB log shows no Vault error during the pause, so on this workload the running server did not need Vault in that time. Vault requests themselves were not logged.
- **B, restart while Vault is paused:** the service stayed `activating` for about 60 s and then went to `failed` (after 66 s with `off`, 65 s with `on`). The log shows a request to Vault ending in a curl timeout (error 28), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. About a minute fits the documented request timeout of 15 s with 3 retries. The service stayed `failed` until Vault was resumed (about 120 s after the restart began), and it did not start again by itself in the following 300 s. A second manual restart brought it back in both runs.
- `use-cache-on-timeout` made no visible difference in either test. For the restart this is expected, because the cache lives in the server process and is empty after a restart.

In short: on this workload a running server rode out a 150 s Vault outage, but a restart during an outage (paused, or stopped as in the observation above) means the server does not start. It stays down until Vault is back and someone starts the service again.

Raw files: `results/claudia/vault_down_off_*` and `vault_down_on_*` (events, summary, restart log, journal excerpt).

### Extra test: operations that need a key

The test above only shows that this workload did not notice a paused Vault. It does not show that a running server never needs Vault:

- The workload reads and updates rows on pages whose keys the server already holds in memory. The plugin only has to ask Vault when it needs something it does not have, for example: a key that is not cached, a new key version, or a new encrypted tablespace.
- In this version the cache timers count CPU time so it is hard to say when entries expire. With four busy workers they should probably have expired during the 150 s pause, but no Vault error was logged so we do not know whether the plugin asked Vault at all.
- A paused Vault makes requests time out, but a stopped Vault refuses connections at once (curl error 7). The running server was only tested with the paused case.

The extra tests are kept apart from the main material in `scripts/extra/` and `results/<name>/extra/`.

Method (`scripts/extra/vault_down_cold.sh`): MariaDB is restarted while Vault is up, and then Vault is paused straight away. Operations that need a key are timed one by one each with a 100 s limit: reading two encrypted tables that have not been read since the restart (key 1 and key 2), updating a row, and creating encrypted tables with key 2 and key 1. The second run adds a table with key 3, a key that exists in Vault but that the server has not used since the restart. Each result is `ok`, an error message or a timeout. Both settings of `use-cache-on-timeout` are tried.

Results (each run with `use-cache-on-timeout` off and on):

- **First run, keys 1 and 2 only:** all six operations succeeded in 0.3 s or less in both modes. Both keys are probably loaded when MariaDB starts (the log shows the key for temporary files, id 2, being loaded at startup), so these operations never needed Vault. Files: `results/<name>/extra/vault_down_cold_run1_*`.
- **Second run, with an operation that needs key 3:** key 3 exists in Vault but the server had not used it since the restart. With Vault paused, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=3` failed after 60.0 s in both modes, with `ERROR 1105 (HY000)`. With `off` the message is `hashicorp: curl returned this error code: 28 ... Operation timed out after 15001 milliseconds with 0 bytes received`: the documented request timeout of 15 s (the 60 s in total fits 4 attempts, the first try and 3 retries). With `on` the message is `hashicorp: Unable to get key data`, which fits a plugin that is allowed to use a cached key after the timeouts and has none for key 3. Full text: `results/<name>/extra/key3_error_off.txt` and `key3_error_on.txt`. The server kept running and answered again once Vault was resumed. The error was reported to the client only; the server log (journal) holds only the startup lines. `use-cache-on-timeout` could not help, because there was no cached key to fall back on. Files: `results/<name>/extra/vault_down_cold_off_*` and `vault_down_cold_on_*`.

So a running server depends on Vault as soon as it needs a key it does not hold in memory, and it only looks independent while every key it uses is already loaded. Not tested: whether the 60 s wait blocks other sessions, an expired cache entry, and key rotation during an outage.

## Still to document

- Key rotation under load: TODO (`scripts/rotate.sh`)
- What the data files show before and after encryption: TODO (`results/<name>/attack_*.txt`)
- What happens when Vault is unavailable: observed once, see the section above; results of the controlled test TODO

## Limits

One machine per person, three runs per configuration and about 10% variation between runs. Numbers depend on the machine.
