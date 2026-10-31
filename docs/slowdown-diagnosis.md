# How the cause of the 93% slowdown was found

[Back to the README](../README.md#findings-one-vault-plugin-setting-caused-a-15x-slowdown). The result is there. This page has the commands and the output of each experiment.


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

