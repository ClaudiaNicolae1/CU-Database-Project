A project for area 10, "Encryption and key management" for the MariaDB student database projects, 2026-09. ([project page](https://mariadb.org/bachelor_hackathon_2026-09/))

# Encryption at rest and key management in MariaDB

Authors: Mercedes Dager, Claudia Nicolae, Francisco Silva, Daris Naska

We encrypt a generated online-shop database (about 4 million rows) with MariaDB table encryption, keep the keys in HashiCorp Vault instead of in a key file, rotate a key while the server is serving traffic, measure the performance cost and look at what someone with only the data files can see.

Two results stand out:

- With the default settings of MariaDB 10.11.14, the Vault key plugin made encrypted throughput about 15 times lower than unencrypted. One plugin option removes the problem (see "Findings").
- When Vault is unreachable, a restart of MariaDB fails, and a running server whose cached key information had expired crashed in both of our runs (see "What happens when the key manager is unavailable").

## What the project covers

| Goal of the area | Where | Status |
|---|---|---|
| Dataset encrypted with a key manager, not a key in a file | `scripts/setup.sh`, `scripts/enable_encryption.sh`, `sql/encrypt_tables.sql` | done |
| Key rotated while the server serves traffic | `scripts/rotate.sh` | results still to be added |
| What the data files show before and after | `scripts/attack_view.sh` | see the section below |
| Performance cost measured, not estimated | `scripts/bench.sh`, `scripts/shop_bench.sh` | done |
| Reproducible from this README, key manager included | `scripts/setup.sh`, `scripts/verify.sh` | done on the authors' machines |
| What happens when the key manager is unavailable | `scripts/vault_down.sh`, `scripts/extra/` | done |

## What is in the repo

- `scripts/`: setup, attacker view, benchmarks, key rotation, checks (`verify.sh`)
- `scripts/extra/`: tests beyond what the area asks (Vault outages)
- `sql/`: schema of the test database (`shop`), the statements that encrypt it, and the query workload
- `results/<name>/`: raw outputs, one folder per person; `extra/` and `experiments/` inside hold the outputs of the extra tests and of the diagnosis

## Requirements and versions

- Ubuntu 24.04, developed on a native install. Other systems are untested.
- MariaDB 10.11.14 (Ubuntu package) with `mariadb-plugin-hashicorp-key-management`
- HashiCorp Vault Vault v2.1.1 (d78bbbe2d2f3d289c1ec29d431071beb23668212), built 2026-09-15T21:21:56Z, run in Docker in dev mode (image `hashicorp/vault`)
- sysbench 1.0.20, g++ (builds the data generator), binutils and xxd (attacker view)
- `sudo` rights and several GB of free disk space

`scripts/setup.sh` installs all of it.

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
bash scripts/verify.sh
bash scripts/attack_view.sh encrypted NAME
bash scripts/shop_bench.sh encrypted NAME
bash scripts/bench.sh encrypted NAME
bash scripts/rotate.sh NAME
```

Use your name instead of `NAME`; your outputs go to `results/NAME/`. Before the encrypted steps, wait until `rotating_or_flushing` is 0 for every row of the query above. The whole run takes about 40 minutes.

Vault runs in Docker in dev mode with the token `root`. This is for the project only. Dev mode keeps keys in memory, so removing the container, or a reboot followed by starting the container again, makes the encrypted tables unreadable (see "What happens when the key manager is unavailable").

`scripts/verify.sh` checks that the running setup is what this README says: the Vault plugin is active, the encryption settings are on, each of the six tables is encrypted with the right key, the row counts match, the name of user 1 is not readable in the raw `users.ibd` file, both keys exist in Vault, and the cache option is set. It exits with a non-zero code if a check fails.

## Data model

The database `shop` has six InnoDB tables (`sql/schema.sql`):

| Table | Key columns | Holds | Encryption key |
|---|---|---|---|
| `users` | `user_id` | name, email, phone, birth date, national id | 2 |
| `addresses` | `address_id`, `user_id` (FK users) | street, city, postal code, country | 2 |
| `payment_methods` | `payment_id`, `user_id` (FK users) | card holder, last 4 digits, token, expiry | 2 |
| `products` | `product_id` | name, category, price | 1 |
| `orders` | `order_id`, `user_id` (FK users) | date, status, total | 1 |
| `order_items` | (`order_id`, `product_id`), FKs to orders and products | quantity, unit price | 1 |

<!-- ER diagram goes here -->

Why it is built this way:

- The personal data (users, addresses, payment methods) is in separate tables from the commerce data, so the two groups can use different keys (2 and 1) and be rotated independently. Rotating key 2 touches only the three personal-data tables, which are much smaller than `orders` and `order_items`.
- `schema.sql` creates every table with `ENCRYPTED=NO`, so the unencrypted baseline can be measured. `encrypt_tables.sql` then converts each table with `ALTER TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=n`. Which key a table uses therefore does not depend on background conversion.
- The data is synthetic, because realistic personal data cannot be published. `scripts/generate_data.cpp` (fixed seed 1) writes CSV files for 200,000 users, 1,000,000 orders and about 2.5 million order items, and `scripts/load_data.sh` loads them with `LOAD DATA LOCAL INFILE`. The structure and size are realistic, the values are not real people. The generated files are not committed (`data/` is ignored); `setup.sh` creates them.

## How encryption is set up in MariaDB

`scripts/enable_encryption.sh` writes `/etc/mysql/mariadb.conf.d/60-encryption.cnf`:

```
[mariadb]
plugin_load_add = hashicorp_key_management
hashicorp-key-management-vault-url = http://127.0.0.1:8200/v1/mariadb
hashicorp-key-management-token = root
hashicorp-key-management-cache-version-timeout = 60000
innodb_encrypt_tables = ON
innodb_encrypt_log = ON
innodb_encryption_threads = 4
encrypt_tmp_files = ON
```

- The plugin reads keys from a Vault KV v2 mount named `mariadb`. `setup.sh` creates two secrets, `mariadb/1` and `mariadb/2`, each with a random 32-byte key (64 hex characters) in the field `data`. The number is the key id used by `ENCRYPTION_KEY_ID`.
- `innodb_encrypt_log` and `encrypt_tmp_files` cover the redo log and temporary files. `innodb_encryption_threads` are the background workers that re-encrypt pages when a key version changes.
- `cache-version-timeout` is the option behind the main finding below.

## Method of the measurements

- Held constant: the same machine, the same MariaDB and OS, the same sysbench parameters, and the same configuration except for encryption.
- sysbench `oltp_read_write` on 8 tables with 500,000 rows each (`sbtest`), 8 threads, 60 s per run, 3 runs per configuration (`scripts/bench.sh`).
- Encrypted runs start only after all eight tables show `encryption_scheme = 1` and `rotating_or_flushing = 0`. `bench.sh` waits for this.
- Metrics: transactions per second and latency (average, 95th percentile) from sysbench. Every run is listed so the spread is visible.
- `scripts/shop_bench.sh` times five queries on the `shop` tables with `mariadb-slap` (`sql/workload.sql`: a point lookup, a join, an update and two full-table aggregations).

## Findings: one Vault plugin setting caused a ~15x slowdown

With the default settings on MariaDB 10.11.14, encrypted throughput fell by 93%. Setting one option brought it back to within about 9% of unencrypted.

Test machine: Lenovo ThinkPad T16 Gen 4, Intel(R) Core(TM) Ultra 5 225U, 14 threads, 32 GB, Ubuntu 24.04, MariaDB 10.11.14, sysbench 1.0.20. Numbers from other machines will differ.

sysbench `oltp_read_write`, 8 threads, 60 s, average of 3 runs (files in `results/claudia/`):

| Configuration | Transactions/s | p95 latency (ms) |
|---|---|---|
| Unencrypted | 2661 | 4.74 |
| Encrypted, default plugin settings | 179 | 272.6 |
| Encrypted, `cache-version-timeout=60000` | 2423 | 6.30 |

The individual runs (transactions/s and p95 latency in ms):

| Configuration | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Unencrypted | 2826 / 4.57 | 2637 / 4.65 | 2521 / 5.00 |
| Encrypted, default plugin settings | 194 / 240.0 | 190 / 227.4 | 153 / 350.3 |
| Encrypted, `cache-version-timeout=60000` | 2661 / 5.67 | 2196 / 6.91 | 2413 / 6.32 |

Runs within one configuration differ by up to about 10%, so the cost of encryption itself (about 9%) is of the same order as the run-to-run variation. We would say 5 to 15%.

What we found:

- **Not the cipher:** the CPU has hardware AES, it was 86 to 87% idle and disk wait was 0 to 2% during the slow phase.
- **Not the redo log:** switching off redo log encryption changed nothing (about 194 to 207 tps).
- **The Vault plugin:** `hashicorp-key-management-cache-version-timeout` defaults to 0 in this version, so the latest key version is looked up in Vault again and again. With Vault's audit log on, a 20 s run produced about 30,600 audit lines (roughly 750 requests per second, assuming about two lines per request). After setting the timeout to 60000 ms, two 60 s runs produced 10 and 26 lines. According to the MariaDB documentation, the default became 60 s in 10.11.15. The same cause is described in the MariaDB bug tracker: [MDEV-30849](https://jira.mariadb.org/browse/MDEV-30849) explains that almost every key read is preceded by a version request to Vault, and [MDEV-33962](https://jira.mariadb.org/browse/MDEV-33962) reports `INSERT ... SELECT` taking about four times as long with the old default. Our mixed read/write benchmark with 8 threads showed a larger effect (about 15 times) on the same cause, and the audit log counts show the requests. So this is a known default that was fixed in 10.11.15, reproduced here on 10.11.14.

The fix is one line in `scripts/enable_encryption.sh`:

```
hashicorp-key-management-cache-version-timeout = 60000
```

Files: `results/claudia/encrypted_defaultcache_run*.txt` (before the fix) and `encrypted_run*.txt` (after). Outputs of the diagnosis: `results/claudia/experiments/` (`debug_encrypted.txt`, `exp_logoff_run1.txt`, `exp_logoff_run2.txt`, `debug_vault_cache.txt`).

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

## Results on different machines

Absolute numbers depend on the machine, so compare the relative change. A `-` means the file for that cell is missing. The table is built from the files in `results/<name>/` by `scripts/compare.sh`.

<!-- compare:start -->
| Person | tps unencrypted | tps encrypted | change | p95 ms unencrypted | p95 ms encrypted | change | shop s unencrypted | shop s encrypted | change |
|---|---|---|---|---|---|---|---|---|---|
| claudia | 2661 | 2423 | -9% | 4.74 | 6.30 | +33% | - | - | - |
| Daris | - | - | - | - | - | - | - | - | - |
| Francisco | - | - | - | - | - | - | - | - | - |
| Mercedes | - | 444 | - | - | 40.53 | - | - | 9.155 | - |
<!-- compare:end -->

## Key rotation while serving traffic

Method and results: TODO, to be added by the team member who runs `scripts/rotate.sh` (errors during the run, how long the new key version took to appear, how long re-encryption took; files in `results/<name>/rotation_*.txt`).

## What the data files show before and after

Method (`scripts/attack_view.sh`): flush `shop.users`, then search the raw `users.ibd` file with `strings` for the email and the name of user 1, and print 128 bytes from page 10 with `xxd`. Done once before and once after encryption.

Result: before encryption the raw `users.ibd` contained the email of user 1 1 time(s) and the name of user 1 1982 time(s). After encryption both counts were 0 and 0. Outputs: `results/claudia/attack_unencrypted.txt` and `results/claudia/attack_encrypted.txt`.

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

Raw files: `results/claudia/vault_down_off_*` and `vault_down_on_*` (events, summary, restart log, journal excerpt).

### Extra tests: what a running server needs from Vault (beyond what the area asks)

The test above only shows that this workload did not notice a paused Vault. It does not show that a running server never needs Vault:

- The workload reads and updates rows on pages whose keys the server already holds in memory. The plugin only has to ask Vault when it needs something it does not have, for example a key that is not cached, a new key version, or a new encrypted tablespace.
- In this version the cache timers count CPU time. During a 150 s load with four workers the server used only about 22 s of CPU time (measured in the extra runs below), well under the 60 s version-cache timeout, so in the first test these entries had most likely not expired yet.
- A paused Vault makes requests time out, but a stopped Vault refuses connections at once (curl error 7). A running server was only tested with the paused case.

The extra tests are kept apart from the main material in `scripts/extra/` and `results/<name>/extra/`.

Method (`scripts/extra/vault_down_cold.sh`): MariaDB is restarted while Vault is up, and then Vault is paused straight away. Operations that need a key are timed one by one each with a 100 s limit: reading two encrypted tables that have not been read since the restart (key 1 and key 2), updating a row, and creating encrypted tables with key 2 and key 1. The second run adds a table with key 3, a key that exists in Vault but that the server has not used since the restart. Each result is `ok`, an error message or a timeout. Both settings of `use-cache-on-timeout` are tried.

Method (`scripts/extra/vault_down_more.sh`): three scenarios, each with a restart while Vault is up and then Vault paused. Scenario 1 starts a `CREATE TABLE` with key 3 that has to wait for Vault, and times other operations meanwhile. Scenario 2 puts a load on the server first (`BURN=1`: full-table scans, which use much more server CPU time than point queries) and then creates encrypted tables with key 2 and key 1. Scenario 3 writes a new version of key 2 right before Vault is paused and logs the key versions.

Results:

- **First run, keys 1 and 2 only:** all six operations succeeded in 0.3 s or less in both modes. Both keys are probably loaded when MariaDB starts (the log shows the key for temporary files, id 2, being loaded at startup), so these operations never needed Vault. Files: `results/<name>/extra/vault_down_cold_run1_*`.
- **Second run, with an operation that needs key 3:** key 3 exists in Vault but the server had not used it since the restart. With Vault paused, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=3` failed after 60.0 s in both modes, with `ERROR 1105 (HY000)`. With `off` the message is `hashicorp: curl returned this error code: 28 ... Operation timed out after 15001 milliseconds with 0 bytes received`: the documented request timeout of 15 s (the 60 s in total fits 4 attempts, the first try and 3 retries). With `on` the message is `hashicorp: Unable to get key data`, which fits a plugin that is allowed to use a cached key after the timeouts and has none for key 3. Full text: `results/<name>/extra/key3_error_off.txt` and `key3_error_on.txt`. The server kept running and answered again once Vault was resumed. The error was reported to the client only; the server log (journal) holds only the startup lines. `use-cache-on-timeout` could not help, because there was no cached key to fall back on. Files: `results/<name>/extra/vault_down_cold_off_*` and `vault_down_cold_on_*`.
- **Does the 60 s wait block other sessions?** Not for operations on keys the server already holds. While a `CREATE TABLE` with key 3 waited 60 s for the paused Vault (and then failed), reads and an update on keys 1 and 2 ran every 3 s and each finished in under 0.1 s. An operation that itself needs an uncached key would wait in the same way. Files: `results/<name>/extra/vault_down_more_s1_off_*`.
- **Does an expired cache entry make an operation fail?** Yes, once the server has used enough CPU time. A first run with point queries used only 22 s of server CPU time in 150 s, under the 60 s version-cache timeout, and showed nothing (`vault_down_more_run1_s2_*`). A load of full-table scans used 333 to 336 s of server CPU time in 90 s. With Vault paused, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=2` after that load ended like this:
  - **`use-cache-on-timeout` off (the default in this version):** the server crashed in both runs, 34.9 s and 42.1 s into the statement. The log shows failed Vault requests (`curl returned this error code: 28 ... Operation timed out after 15002 milliseconds`, `Unable to get key data`), then `InnoDB: Failing assertion: key_version != ENCRYPTION_KEY_VERSION_INVALID` and `signal 6`. systemd started MariaDB again a few seconds later (the unit has `Restart=on-abnormal`) without anyone restarting it, and `scripts/verify.sh` passed afterwards. Files: `results/<name>/extra/vault_down_more_crash_s2_off_*` and `vault_down_more_s2_off_crash_journal.txt` (first run), `vault_down_more_repeat_s2_off_*` (second run).
  - **`use-cache-on-timeout` on:** the server stayed up. With a 100 s limit both `CREATE TABLE` statements (key 2 and key 1) were still waiting (`vault_down_more_burn100_s2_on_*`). With a 300 s limit they finished after 160 s (key 2) and 120 s (key 1), so they waited through several 60 s Vault lookups before using the cached value, while a plain read stayed instant (`vault_down_more_s2_on_*`).
  
  The same assertion is in MariaDB's bug tracker for other situations ([MDEV-9948](https://jira.mariadb.org/browse/MDEV-9948), [MDEV-8817](https://jira.mariadb.org/browse/MDEV-8817), and the open [MDEV-38141](https://jira.mariadb.org/browse/MDEV-38141) with the Vault plugin on 12.2). We did not find a report with this trigger, but we only searched briefly.
- **Key rotation during an outage:** not concluded. The one run of scenario 3 used too little server CPU time for the version cache to expire, so the key versions never changed, during the outage or after it (`vault_down_more_s3_off_*`).

So a running server depends on Vault as soon as it needs a key it does not hold in memory, and also once a cached entry has expired. Until then it looks independent of Vault. With an unreachable Vault, an expired entry made the server abort (`use-cache-on-timeout` off, seen in 2 of 2 runs) or stall for minutes (on, one run each of the 100 s and 300 s limits).

## Limits

- One machine per person, three runs per configuration and about 10% variation between runs. Numbers depend on the machine.
- All results are from MariaDB 10.11.14 (the Ubuntu 24.04 package). According to the documentation, the Vault plugin's defaults changed in 10.11.15, 10.11.16 and 10.11.19 (version cache timeout, use of cached keys on timeout, and wall-clock instead of CPU time for cache timers), so newer releases may behave differently. We did not test them.
- The extra tests are single runs, except the crash (two runs). They show what happened on this machine, not how often.
- Vault runs in dev mode with the token `root`, and the benchmark user has the password `sbtest`. Both are hardcoded for the project and must never be used for real data.
- The Docker image `hashicorp/vault` is not pinned to a version, so a later image may behave differently.
- The binary log is not enabled, so binlog encryption is not covered.
- A stopped Vault (connection refused) was only observed at startup, not on a running server, because dev mode loses its keys when the process stops.
- Tested on Ubuntu 24.04 only. The only automated check is `scripts/verify.sh`; there is no CI.
