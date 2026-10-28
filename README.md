A project for area 10, "Encryption and key management" for the MariaDB student database projects, 2026-09. ([project page](https://mariadb.org/bachelor_hackathon_2026-09/))

# Encryption at rest and key management in MariaDB

Authors: Mercedes Dager, Claudia Nicolae, Francisco Silva, Daris Naska

We encrypt a generated online-shop database (about 4 million rows) with MariaDB table encryption and keep the keys in HashiCorp Vault instead of in a key file. We rotate a key while the server is running, measure what encryption costs, and check what someone who only has the data files can see.

Two results stand out:

- **A plugin default made encryption 15 times slower.** On MariaDB 10.11.14, the Vault key plugin cut throughput by 93% with its default settings. One option fixes it (see "Findings").
- **An unreachable Vault can take the server down.** MariaDB does not start without Vault. A running server crashed in both of our runs once its cached key information had expired (see "What happens when the key manager is unavailable").

## Contents

- [What the project covers](#what-the-project-covers): the goals of the area and where each one is done
- [What is in the repo](#what-is-in-the-repo)
- [Requirements and versions](#requirements-and-versions)
- [Setup (Ubuntu 24.04)](#setup-ubuntu-2404): the commands to reproduce everything
- [Data model](#data-model): the six tables and why they are split this way
- [How encryption is set up in MariaDB](#how-encryption-is-set-up-in-mariadb)
- [Method of the measurements](#method-of-the-measurements)
- [Findings: one Vault plugin setting caused a ~15x slowdown](#findings-one-vault-plugin-setting-caused-a-15x-slowdown): the main result
  - [How the cause was found](#how-the-cause-was-found)
- [Results on different machines](#results-on-different-machines)
- [Key rotation while serving traffic](#key-rotation-while-serving-traffic)
- [What the data files show before and after](#what-the-data-files-show-before-and-after)
- [What happens when the key manager is unavailable](#what-happens-when-the-key-manager-is-unavailable): the observation, the controlled test and the extra tests
  - [Extra tests: what a running server needs from Vault](#extra-tests-what-a-running-server-needs-from-vault-beyond-what-the-area-asks)
- [Limits](#limits)

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
- `results/<name>/`: raw outputs, one folder per person. The `extra/` and `experiments/` folders inside hold the outputs of the extra tests and of the diagnosis.

## Requirements and versions

- Ubuntu 24.04 on a native install. Other systems are untested.
- MariaDB 10.11.14 (Ubuntu package) with `mariadb-plugin-hashicorp-key-management`
- HashiCorp Vault 2.1.1, run in Docker in dev mode (image `hashicorp/vault`)
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

Use your own name instead of `NAME`. Your results go to `results/NAME/`. Before the encrypted steps, wait until `rotating_or_flushing` is 0 for every row of the query above. The full run takes about 40 minutes.

Vault runs in Docker in dev mode with the token `root`. This is only for the project. Dev mode keeps keys in memory, so if the container is removed, or restarted after a reboot, the keys are gone and the encrypted tables cannot be read (see "What happens when the key manager is unavailable").

`scripts/verify.sh` checks the running setup against this README. It checks that the Vault plugin is active, that encryption is on, that each of the six tables uses the right key, that the row counts match, that the name of user 1 cannot be found in the raw `users.ibd` file, that both keys exist in Vault, and that the cache option is set. It exits with a non-zero code if any check fails.

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

- The personal data (users, addresses, payment methods) sits in separate tables from the shop data, so the two groups can use different keys (2 and 1) and be rotated separately. Rotating key 2 touches only three small tables. `orders` and `order_items` are much bigger.
- `schema.sql` creates every table with `ENCRYPTED=NO`, so we can measure an unencrypted baseline. `encrypt_tables.sql` then encrypts each table with `ALTER TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=n`. Each table's key is set explicitly and does not depend on background conversion.
- The data is synthetic, because real personal data cannot be published. `scripts/generate_data.cpp` (fixed seed 1) writes CSV files for 200,000 users, 1,000,000 orders and about 2.5 million order items, and `scripts/load_data.sh` loads them with `LOAD DATA LOCAL INFILE`. The structure and size are realistic, but the values are not real people. The generated files are not committed (`data/` is ignored). `setup.sh` creates them.

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

- The plugin reads keys from a Vault KV v2 mount named `mariadb`. `setup.sh` creates two secrets, `mariadb/1` and `mariadb/2`. Each holds a random 32-byte key (64 hex characters) in the field `data`. The number is the key id that `ENCRYPTION_KEY_ID` refers to.
- `innodb_encrypt_log` and `encrypt_tmp_files` cover the redo log and temporary files. `innodb_encryption_threads` are the background workers that re-encrypt pages when a key version changes.
- `cache-version-timeout` is the option behind the main finding below.

## Method of the measurements

- Held constant: the same machine, MariaDB and OS, the same sysbench parameters, and the same configuration apart from encryption.
- sysbench `oltp_read_write` on 8 tables with 500,000 rows each (`sbtest`), 8 threads, 60 s per run, 3 runs per configuration (`scripts/bench.sh`).
- Encrypted runs start only after all eight tables show `encryption_scheme = 1` and `rotating_or_flushing = 0`. `bench.sh` waits for this.
- Metrics: transactions per second and latency (average and 95th percentile) from sysbench. We list every run so the spread is visible.
- `scripts/shop_bench.sh` times five queries on the `shop` tables with `mariadb-slap` (`sql/workload.sql`): a point lookup, a join, an update and two full-table aggregations.

## Findings: one Vault plugin setting caused a ~15x slowdown

On MariaDB 10.11.14, encrypted throughput dropped by 93% with the default settings. One option brought it back to within about 9% of unencrypted.

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

Runs within one configuration differ by up to about 10%, so the real cost of encryption (about 9%) is hard to tell apart from the noise. We would call it 5 to 15%.

What we found:

- **Not the cipher.** The CPU has hardware AES. It was 86 to 87% idle and disk wait was 0 to 2% while the runs were slow.
- **Not the redo log.** Turning off redo log encryption changed nothing (about 194 to 207 tps).
- **The Vault plugin.** In this version, `hashicorp-key-management-cache-version-timeout` defaults to 0, so the plugin asks Vault for the latest key version again and again. With Vault's audit log on, a 20 s run wrote about 30,600 lines. That is roughly 750 requests per second, if each request logs two lines. After we set the timeout to 60000 ms, two 60 s runs wrote 10 and 26 lines. The MariaDB documentation says the default became 60 s in 10.11.15.

MariaDB's bug tracker describes the same cause. [MDEV-30849](https://jira.mariadb.org/browse/MDEV-30849) explains that almost every key read starts with a version request to Vault. [MDEV-33962](https://jira.mariadb.org/browse/MDEV-33962) reports `INSERT ... SELECT` taking about four times as long with the old default. Our mixed read/write benchmark with 8 threads saw about 15 times. So this is a known default that was fixed in 10.11.15, and we reproduced it on 10.11.14.

The fix is one line in `scripts/enable_encryption.sh`:

```
hashicorp-key-management-cache-version-timeout = 60000
```

Files: `results/claudia/encrypted_defaultcache_run*.txt` (before the fix) and `encrypted_run*.txt` (after). Outputs of the diagnosis: `results/claudia/experiments/` (`debug_encrypted.txt`, `exp_logoff_run1.txt`, `exp_logoff_run2.txt`, `debug_vault_cache.txt`).

### How the cause was found

```bash
SB="--mysql-socket=/run/mysqld/mysqld.sock --mysql-user=sbtest --mysql-password=sbtest --mysql-db=sbtest --tables=8 --table-size=500000"
```

**1. Is it the cipher?** Check that the CPU has AES instructions, and watch CPU and disk during an encrypted run (`id` is CPU idle %, `wa` is disk wait %):

```bash
grep -m1 -o aes /proc/cpuinfo
vmstat 10 6 > /tmp/vm.txt &
sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run
wait
cat /tmp/vm.txt
```

Result: `aes` was present. The first row of the `vmstat` output is an average since boot, so ignore it. CPU idle was 70% in the first 10 s, while throughput was still high, then 86 to 87%. Disk wait was 0 to 2%.

**2. Is it the redo log?** Turn off redo log encryption, restart, and run twice:

```bash
sudo sed -i 's/innodb_encrypt_log = ON/innodb_encrypt_log = OFF/' /etc/mysql/mariadb.conf.d/60-encryption.cnf
sudo systemctl restart mariadb
for i in 1 2; do sysbench oltp_read_write $SB --threads=8 --time=60 --report-interval=10 run; done
```

Result: 194 and 207 tps, the same as with it on. The setting stayed off for the first part of step 3.

**3. Is it the Vault plugin?** Turn on Vault's audit log and count its lines around a run:

```bash
v() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault vault "$@"; }
v audit enable file file_path=stdout
docker logs vault 2>&1 | wc -l
sysbench oltp_read_write $SB --threads=8 --time=20 run
docker logs vault 2>&1 | wc -l
```

Result with the default settings (redo log encryption was still off in this run): about 30,600 new audit lines in 20 s. Then we turned redo log encryption back on, set the cache option, restarted, and counted around two 60 s runs:

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

Result: 10 and 26 new lines, and throughput back to about 2400 tps. The restart in between wrote about 9,700 audit lines, but those fall outside the benchmark runs. InnoDB's own `keyserver_requests` counter did not change during a slow run (19 before and after), so it does not show these lookups. The audit log does.

The option and its default are described in the [MariaDB documentation](https://mariadb.com/docs/server/security/encryption/data-at-rest-encryption/key-management-and-encryption-plugins/hashicorp-key-management-plugin).

## Results on different machines

Absolute numbers depend on the machine, so compare the relative change. A `-` means that file is missing. `scripts/compare.sh` builds the table from the files in `results/<name>/`.

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

Method (`scripts/attack_view.sh`): flush `shop.users`, search the raw `users.ibd` file with `strings` for the email and the name of user 1, and print 128 bytes from page 10 with `xxd`. We do this once before and once after encryption.

Result: before encryption, the raw `users.ibd` file contained the email of user 1 once and the name of user 1 1,982 times. After encryption, neither was found (0 and 0). Outputs: `results/claudia/attack_unencrypted.txt` and `results/claudia/attack_encrypted.txt`.

## What happens when the key manager is unavailable

We looked at four situations. The table sums up what happened, and the sections below give the details.

| Situation | What happened |
|---|---|
| Vault is stopped when MariaDB starts (after a reboot) | MariaDB does not start |
| Vault is paused while MariaDB restarts | MariaDB fails after about 60 s and stays down until someone restarts it |
| Vault is paused while the server runs normal queries | No effect for 150 s |
| Vault is paused and the server needs a key it has not used | The operation fails after 60 s. Other sessions are not blocked |
| Vault is paused and cached key information has expired | With `use-cache-on-timeout` off: the server crashed (2 of 2 runs) and systemd restarted it. With `on`: the server stayed up, but key operations waited 2 to 3 minutes |

**After a reboot.** The Vault container was not running, so port 8200 refused connections, and MariaDB did not start at all. The error log shows the plugin failing its first request to Vault (`curl returned this error code: 7 ... Failed to connect to 127.0.0.1 port 8200`), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. Dev-mode Vault keeps its keys in memory, so starting the container again gave an empty Vault. The keys were gone, the encrypted data could not be read, and we rebuilt the databases with `scripts/setup.sh`. Log lines: `results/claudia/vault_stopped_at_startup.txt`.

**Controlled test (`scripts/vault_down.sh`).** We pause the Vault container, so it stops answering but keeps its keys in memory.

- **Test A:** four workers read and update the `shop` tables for 240 s. Vault is paused from second 20 to second 170. We log the duration and result of every round.
- **Test B:** MariaDB is restarted while Vault is paused. We log the service state and a test query every 5 s. Then we resume Vault and record how long MariaDB takes to answer.

Both tests ran once with `hashicorp-key-management-use-cache-on-timeout` set to `off` and once set to `on`.

For comparison, this is what the MariaDB documentation says about this version (10.11.14):

- When Vault does not answer, the plugin waits `hashicorp-key-management-timeout` (15 s by default) per request and retries 3 times.
- `use-cache-on-timeout` is `OFF` by default here and covers only timeouts. From 10.11.16 it is `ON` by default and covers all errors, so a server keeps running on cached keys while Vault is briefly unreachable.
- Keys and key versions are cached. In this version the cache times (including our `cache-version-timeout`) are measured in process CPU time, not wall-clock time. This was fixed in 10.11.19.
- The plugin does not unseal Vault by itself.

Results (both settings gave the same picture):

- **Test A, Vault paused for 150 s.** The workers ran 41,661 rounds (`off`) and 41,983 rounds (`on`) of reads and updates, with no errors. An average round took 0.02 s and the slowest 0.03 s. The rate during the pause (about 1,750 rounds per 10 s) matched the rate before it. The MariaDB log shows no Vault error during the pause, so on this workload the server did not need Vault in that time. We did not log Vault's own requests.
- **Test B, restart while Vault is paused.** The service stayed in `activating` for about 60 s, then went to `failed` (after 66 s with `off`, 65 s with `on`). The log shows a Vault request ending in a curl timeout (error 28), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. One minute matches the documented 15 s timeout with 3 retries. MariaDB stayed `failed` after Vault came back (about 120 s into the test) and did not start again by itself in the next 300 s. A manual restart brought it back in both runs.
- **`use-cache-on-timeout` made no difference** in either test. For the restart that is expected, because the cache lives in the server process and is empty after a restart.

Raw files: `results/claudia/vault_down_off_*` and `vault_down_on_*` (events, summary, restart log, journal excerpt).

### Extra tests: what a running server needs from Vault (beyond what the area asks)

Test A only shows that this workload did not notice a paused Vault. That does not mean a running server never needs Vault:

- The workload only reads and updates pages whose keys the server already has in memory. The plugin asks Vault only when it needs something it does not have: an uncached key, a new key version, or a new encrypted table.
- In this version the cache timers count CPU time. During a 150 s load with four workers, the server used only about 22 s of CPU time (measured in the extra runs below). That is far below the 60 s version-cache timeout, so in test A the cache entries had most likely not expired.
- A paused Vault makes requests time out. A stopped Vault refuses connections at once (curl error 7). We tested a running server only with a paused Vault.

The extra tests and their results are kept apart from the main material, in `scripts/extra/` and `results/<name>/extra/`.

Two scripts:

- `scripts/extra/vault_down_cold.sh`: MariaDB is restarted with Vault up, then Vault is paused right away. We time operations that need a key, each with a 100 s limit: reading two encrypted tables that were not read since the restart (keys 1 and 2), updating a row, and creating encrypted tables with key 2 and key 1. A second run adds a table with key 3, which exists in Vault but has not been used by the server since the restart. Each result is `ok`, an error or a timeout. We ran it with `use-cache-on-timeout` both `off` and `on`.
- `scripts/extra/vault_down_more.sh`: three scenarios, each with a restart while Vault is up and then Vault paused. Scenario 1 starts a `CREATE TABLE` with key 3 that has to wait for Vault, and times other operations meanwhile. Scenario 2 first loads the server (`BURN=1` runs full-table scans, which use far more server CPU time than point queries) and then creates encrypted tables with key 2 and key 1. Scenario 3 writes a new version of key 2 just before Vault is paused and logs the key versions.

Results:

- **Keys 1 and 2 only.** All six operations succeeded in 0.3 s or less, in both modes. MariaDB probably loads both keys at startup (the log shows the key for temporary files, id 2, loaded then), so these operations never needed Vault. Files: `results/<name>/extra/vault_down_cold_run1_*`.
- **A key the server had not used (key 3).** With Vault paused, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=3` failed after 60.0 s in both modes with `ERROR 1105 (HY000)`. With `off`, the message was `hashicorp: curl returned this error code: 28 ... Operation timed out after 15001 milliseconds with 0 bytes received`. That is the documented 15 s timeout, tried four times (the first try plus 3 retries). With `on`, the message was `hashicorp: Unable to get key data`. Our reading is that the plugin tried to fall back on a cached key and had none for key 3. The server kept running and answered again once Vault was back. The error only reached the client. The server log held only the startup lines. Full text: `results/<name>/extra/key3_error_off.txt` and `key3_error_on.txt`. Files: `results/<name>/extra/vault_down_cold_off_*` and `vault_down_cold_on_*`.
- **Does the wait block other sessions?** No. While a `CREATE TABLE` with key 3 waited 60 s for the paused Vault, reads and an update on keys 1 and 2 ran every 3 s, and each took under 0.1 s. An operation that itself needs an uncached key would wait the same way. Files: `results/<name>/extra/vault_down_more_s1_off_*`.
- **Does an expired cache entry cause failures?** Yes, once the server has used enough CPU time. The point-query load used only 22 s of CPU in 150 s and showed nothing (`vault_down_more_run1_s2_*`). Full-table scans used 333 to 336 s in 90 s. With Vault paused, `CREATE TABLE ... ENCRYPTION_KEY_ID=2` after that load went like this:
  - **`use-cache-on-timeout` off (the default in this version):** the server crashed in both runs, 34.9 s and 42.1 s into the statement. The log shows failed Vault requests (curl error 28 after 15002 ms, then `Unable to get key data`), then `InnoDB: Failing assertion: key_version != ENCRYPTION_KEY_VERSION_INVALID` and `signal 6`. systemd restarted MariaDB a few seconds later (the unit has `Restart=on-abnormal`), and `scripts/verify.sh` passed afterwards. Files: `results/<name>/extra/vault_down_more_crash_s2_off_*` and `vault_down_more_s2_off_crash_journal.txt` (first run), `vault_down_more_repeat_s2_off_*` (second run).
  - **`use-cache-on-timeout` on:** the server stayed up. With a 100 s limit, both `CREATE TABLE` statements (key 2 and key 1) were still waiting (`vault_down_more_burn100_s2_on_*`). With a 300 s limit they finished after 160 s (key 2) and 120 s (key 1), and a plain read stayed instant (`vault_down_more_s2_on_*`).

  MariaDB's bug tracker lists the same assertion for other situations: [MDEV-9948](https://jira.mariadb.org/browse/MDEV-9948), [MDEV-8817](https://jira.mariadb.org/browse/MDEV-8817), and the open [MDEV-38141](https://jira.mariadb.org/browse/MDEV-38141) (Vault plugin, 12.2). We did not find a report with this trigger, though we only searched briefly.
- **Key rotation during an outage.** Not concluded. Scenario 3 ran only once and used too little server CPU time for the version cache to expire, so the key versions never changed, during the outage or after it (`vault_down_more_s3_off_*`).

In short, a running server needs Vault as soon as it needs a key it does not hold in memory, or once a cached entry has expired. Until then it looks independent of Vault. With Vault unreachable, an expired entry made the server crash (`use-cache-on-timeout` off, 2 of 2 runs) or stall for minutes (`on`, one run each at the 100 s and 300 s limits).

## Limits

- One machine per person, three runs per configuration, and about 10% variation between runs. Numbers depend on the machine.
- All results come from MariaDB 10.11.14 (the Ubuntu 24.04 package). According to the documentation, the Vault plugin's defaults changed in 10.11.15, 10.11.16 and 10.11.19 (version cache timeout, use of cached keys on timeout, wall-clock instead of CPU time for cache timers), so newer releases may behave differently. We did not test them.
- The extra tests are single runs, except the crash (two runs).
- Vault runs in dev mode with the token `root`, and the benchmark user has the password `sbtest`. Both are hardcoded.
- The Docker image `hashicorp/vault` is not pinned to a version.
- The binary log is not enabled, so binlog encryption is not covered.
- We tested only on Ubuntu 24.04. The only automated check is `scripts/verify.sh`.
