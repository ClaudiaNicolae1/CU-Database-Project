# What happens when the key manager is unavailable: details

[Back to the README](../README.md#what-happens-when-the-key-manager-is-unavailable). The summary table is there. This page has the observation after a reboot, the controlled test, what the MariaDB documentation says, and the extra tests, with every number and file name.

**After a reboot.** The Vault container was not running, so port 8200 refused connections, and MariaDB did not start at all. The error log shows the plugin failing its first request to Vault (`curl returned this error code: 7 ... Failed to connect to 127.0.0.1 port 8200`), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. Dev-mode Vault keeps its keys in memory, so starting the container again gave an empty Vault. The keys were gone, the encrypted data could not be read, and we rebuilt the databases with `scripts/setup.sh`. Log lines: `results/claudia/vault_stopped_at_startup.txt`.

**Controlled test (`scripts/vault_down.sh`).** We pause the Vault container, so it stops answering but keeps the keys in memory.

- **Test A:** four workers read and update the `shop` tables for 240 s. Vault is paused from second 20 to second 170. We log the duration and result of every round.
- **Test B:** MariaDB is restarted while Vault is paused. We log the service state and a test query every 5 s. Then we resume Vault and record how long MariaDB takes to answer.

Both tests ran once with `hashicorp-key-management-use-cache-on-timeout` set to `off` and once set to `on`.

For comparison, this is what the MariaDB documentation says about this version (10.11.14):

- When Vault does not answer, the plugin waits `hashicorp-key-management-timeout` (15 s by default) per request and retries 3 times.
- `use-cache-on-timeout` is `OFF` by default here and covers only timeouts. From 10.11.16 it is `ON` by default and covers all errors, so a server keeps running on cached keys while Vault is briefly unreachable.
- Keys and key versions are cached. In this version the cache times (including our `cache-version-timeout`) are measured in process CPU time, not wall-clock time. This was fixed in 10.11.19.
- The plugin does not unseal Vault by itself.

Results (both settings gave the same picture):

- **Test A, Vault paused for 150 s.** The workers ran 41,661 rounds (`off`) and 41,983 rounds (`on`) of reads and updates, with no errors. An average round took 0.02 s and the slowest 0.03 s. The rate during the pause (about 1,750 rounds per 10 s) matched the rate before it. The MariaDB log shows no Vault error during the pause, so on this workload the server did not need Vault in that time.
- **Test B, restart while Vault is paused.** The service stayed in `activating` for about 60 s, then went to `failed` (after 66 s with `off`, 65 s with `on`). The log shows a Vault request ending in a curl timeout (error 28), then `Plugin 'hashicorp_key_management' init function returned error`, `InnoDB: cannot enable encryption, encryption plugin is not available` and `Aborting`. One minute matches the documented 15 s timeout with 3 retries. MariaDB stayed `failed` after Vault came back (about 120 s into the test) and did not start again by itself in the next 300 s. A manual restart brought it back in both runs.
- **`use-cache-on-timeout` made no difference** in either test.

Files: `results/claudia/vault_down_off_*` and `vault_down_on_*` (events, summary, restart log, journal excerpt).

## Extra tests: what a running server needs from Vault (beyond what the area asks)

Test A only shows that this workload did not notice a paused Vault, but that does not mean a running server never needs Vault:

- The workload only reads and updates pages whose keys the server already has in memory. The plugin asks Vault only when it needs something it does not have: an uncached key, a new key version, or a new encrypted table.
- In this version the cache timers count CPU time. During a 150 s load with four workers, the server used only about 22 s of CPU time (measured in the extra runs below). That is far below the 60 s version-cache timeout, so in test A the cache entries had most likely not expired.
- A paused Vault makes requests time out. A stopped Vault refuses connections at once (curl error 7). We tested a running server only with a paused Vault.

The extra tests and their results are kept apart from the main material, in `scripts/extra/` and `results/claudia/extra/`.

Two scripts:

- `scripts/extra/vault_down_cold.sh`: MariaDB is restarted with Vault up, then Vault is paused right away. We time operations that need a key, each with a 100 s limit: reading two encrypted tables that were not read since the restart (keys 1 and 2), updating a row, and creating encrypted tables with key 2 and key 1. A second run adds a table with key 3, which exists in Vault but has not been used by the server since the restart. Each result is `ok`, an error or a timeout. We ran it with `use-cache-on-timeout` both `off` and `on`.
- `scripts/extra/vault_down_more.sh`: three scenarios, each with a restart while Vault is up and then Vault paused. Scenario 1 starts a `CREATE TABLE` with key 3 that has to wait for Vault, and times other operations meanwhile. Scenario 2 first loads the server (`BURN=1` runs full-table scans, which use far more server CPU time than point queries) and then creates encrypted tables with key 2 and key 1. Scenario 3 writes a new version of key 2 just before Vault is paused and logs the key versions.

Results:

- **Keys 1 and 2 only.** All six operations succeeded in 0.3 s or less, in both modes. MariaDB probably loads both keys at startup (the log shows the key for temporary files, id 2, loaded then), so these operations never needed Vault. Files: `results/claudia/extra/vault_down_cold_run1_*`.
- **A key the server had not used (key 3).** With Vault paused, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=3` failed after 60.0 s in both modes with `ERROR 1105 (HY000)`. With `off`, the message was `hashicorp: curl returned this error code: 28 ... Operation timed out after 15001 milliseconds with 0 bytes received`. That is the documented 15 s timeout, tried four times (the first try plus 3 retries). With `on`, the message was `hashicorp: Unable to get key data`. Our reading is that the plugin tried to fall back on a cached key and had none for key 3. The server kept running and answered again once Vault was back. The error only reached the client. The server log held only the startup lines. Full text: `results/claudia/extra/key3_error_off.txt` and `key3_error_on.txt`. Files: `results/claudia/extra/vault_down_cold_off_*` and `vault_down_cold_on_*`.
- **Does the wait block other sessions?** No. While a `CREATE TABLE` with key 3 waited 60 s for the paused Vault, reads and an update on keys 1 and 2 ran every 3 s, and each took under 0.1 s. An operation that itself needs an uncached key would wait the same way. Files: `results/claudia/extra/vault_down_more_s1_off_*`.
- **Does an expired cache entry cause failures?** Yes, once the server has used enough CPU time. The point-query load used only 22 s of CPU in 150 s and showed nothing (`vault_down_more_run1_s2_*`). Full-table scans used 333 to 336 s in 90 s. With Vault paused, `CREATE TABLE ... ENCRYPTION_KEY_ID=2` after that load went like this:
  - **`use-cache-on-timeout` off (the default in this version):** the server crashed in both runs, 34.9 s and 42.1 s into the statement. The log shows failed Vault requests (curl error 28 after 15002 ms, then `Unable to get key data`), then `InnoDB: Failing assertion: key_version != ENCRYPTION_KEY_VERSION_INVALID` and `signal 6`. systemd restarted MariaDB a few seconds later (the unit has `Restart=on-abnormal`), and `scripts/verify.sh` passed afterwards. Files: `results/claudia/extra/vault_down_more_crash_s2_off_*` and `vault_down_more_s2_off_crash_journal.txt` (first run), `vault_down_more_repeat_s2_off_*` (second run).
  - **`use-cache-on-timeout` on:** the server stayed up. With a 100 s limit, both `CREATE TABLE` statements (key 2 and key 1) were still waiting (`vault_down_more_burn100_s2_on_*`). With a 300 s limit they finished after 160 s (key 2) and 120 s (key 1), and a plain read stayed instant (`vault_down_more_s2_on_*`).

  MariaDB's bug tracker lists the same assertion for other situations: [MDEV-9948](https://jira.mariadb.org/browse/MDEV-9948), [MDEV-8817](https://jira.mariadb.org/browse/MDEV-8817), and the open [MDEV-38141](https://jira.mariadb.org/browse/MDEV-38141) (Vault plugin, 12.2). We did not find a report with this trigger, though we only searched briefly.
- **A key id that is missing from Vault (Vault is up).** With key id 99, which does not exist in Vault, `CREATE TABLE ... ENCRYPTED=YES ENCRYPTION_KEY_ID=99` failed with `ERROR 1005 (HY000)` and errno 140 "Wrong create options". An `ALTER TABLE` to key id 99 on an existing table failed with `ERROR 1478 (HY000): Table storage engine 'InnoDB' does not support the create option 'ENCRYPTION_KEY_ID'`. Neither message mentions the key, and both point at table options. The server log has the real cause: `hashicorp: Key not found (key id: 99)`. It is logged as a note, not as an error, so a search of the log for errors would miss it. Anyone who gets one of these errors should check the log and the key ids in Vault first. Files: `results/claudia/extra/missing_key_error.txt` and `missing_key_journal.txt`.
- **Key rotation during an outage.** Not concluded. Scenario 3 ran only once and used too little server CPU time for the version cache to expire, so the key versions never changed, during the outage or after it (`vault_down_more_s3_off_*`).

In short, a running server needs Vault as soon as it needs a key it does not hold in memory, or once a cached entry has expired. Until then it looks independent of Vault. With Vault unreachable, an expired entry made the server crash (`use-cache-on-timeout` off, 2 of 2 runs) or stall for minutes (`on`, one run each at the 100 s and 300 s limits).

