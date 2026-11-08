# Key rotation while serving traffic: details

[Back to the README](../README.md#key-rotation-while-serving-traffic). The summary is there. This page has the method, the results of the three rotation runs, and the probe that checked whether a rotation slows the server down.

## Method

`scripts/rotate_under_load.sh` writes a new version of key 2 to Vault twice, at 20 s and at 60 s into a 240 s run, while 6 workers keep querying the `shop` tables. Four workers run full-table scans on `orders` (they use a lot of server CPU time, which the plugin's cache timers count). Two workers read and update the three tables that use key 2. Every 5 s the script records the key versions MariaDB sees, how many tables are still rotating and how many pages were re-encrypted. A control run uses the same load and writes no key.

We ran it three times with rotation and three times as a control, on one laptop:

| Run | Kind | Files |
|---|---|---|
| first run | rotation (inside `run_all.sh`) | `results/claudia2/rotation_events.txt`, `rotation_progress.txt`, `rotation_summary.txt` |
| first control | control | `results/claudia2/control/` |
| rotate1, rotate2 | rotation (in the probe below) | `results/claudia2/probe/rotate1/`, `results/claudia2/probe/rotate2/` |
| control1, control2 | control (in the probe below) | `results/claudia2/probe/control1/`, `results/claudia2/probe/control2/` |

## Results of the three rotation runs

**No errors.** The three rotation runs made 57,944 rounds of scans, reads and updates in total, and none failed. The slowest round in any rotation run was 0.52 s for a scan and 0.06 s for a read or update. The controls reached 0.40 s and 0.07 s.

**MariaDB does not use a new key version at once, but within 15 s.** The first run showed it at the very next poll, which made it look immediate. The two repeats show a delay of up to 15 s. Polls were every 5 s, so the delays are accurate to about 5 s.

| Run | First new version written | Seen by MariaDB | Second new version written | Seen by MariaDB |
|---|---|---|---|---|
| first run | 20 s | 20 s | 61 s | 61 s |
| rotate1 | 20 s | 35 s | 60 s | 71 s |
| rotate2 | 20 s | 26 s | 61 s | 71 s |

In this version the plugin's cache timers count the server's CPU time, not wall-clock time. The server used about 5 cores here, so 60 s of CPU time pass in about 12 s. That fits delays of up to about 12 s plus the 5 s polling step, but we did not test it.

**Old pages are re-encrypted when they are more than one key version behind.** The pattern is the same in all three rotation runs: the first new version re-encrypts almost nothing, and the second one re-encrypts about 2,600 pages. Each time, the re-encryption was finished by the next 5 s poll after MariaDB picked the version up.

| Run | Pages re-encrypted after the first new version | After the second | Key versions at the end (min / max) |
|---|---|---|---|
| first run | 0 | 2,699 | 2 / 3 |
| rotate1 | 5 | 2,616 | 4 / 5 |
| rotate2 | 38 | 2,616 | 6 / 7 |

This fits the default `innodb_encryption_rotate_key_age=1`. We did not test that setting. In both repeated rotations the background threads also read 3,832 pages from the cache.

**No measurable slowdown over a whole run.** The rotation runs did on average 0.6% fewer scans and 1.4% fewer reads and updates than the controls, which is less than the difference between two runs of the same kind.

| Run | Kind | Scan rounds | Read and update rounds |
|---|---|---|---|
| first run | rotation | 3,763 | 15,085 |
| rotate1 | rotation | 3,782 | 15,466 |
| rotate2 | rotation | 3,876 | 15,972 |
| first control | control | 3,846 | 15,791 |
| control1 | control | 3,788 | 15,542 |
| control2 | control | 3,851 | 15,842 |
| mean, rotation / control | | 3,807 / 3,828 (−0.6%) | 15,508 / 15,725 (−1.4%) |

## The step down in the first run, and the probe

In the first rotation run, throughput fell by about 13% after the second new key version and stayed lower until the end of the run (scan rounds per 10 s: 173 before 60 s, 150 after). The first control stayed flat. The re-encryption was finished within 5 s, so it could not explain a slowdown that lasted about 170 s. We built a probe to find the cause.

### Method of the probe

`scripts/extra/rotation_probe.sh` runs the same load as `scripts/rotate_under_load.sh` and, every 5 s, records signals that could explain a change in throughput:

- CPU clock speed (mean over all cores) and the highest temperature
- the number of lines in Vault's log, with Vault's audit log switched on, so every request shows up as lines
- the CPU time used by the MariaDB server
- CPU idle and iowait from `vmstat`
- all of InnoDB's encryption counters

We ran four runs in the order control, rotation, control, rotation, with 60 s between them, so that slow drift (heat, background tasks) affects both kinds evenly. `scripts/extra/rotation_probe_summary.sh` compares, for each run, the mean of every signal before the second new key version (5 to 55 s) with the mean after it (65 to 225 s).

| Hypothesis | What would show it |
|---|---|
| The laptop slowed down | Clock speed or temperature changes after 60 s, only in rotation runs |
| Vault was asked for more after the new versions | The rate of Vault log lines jumps after 60 s, only in rotation runs |
| Background re-encryption or flushing kept working | Server CPU, idle or iowait change after 60 s, or the counters keep growing |
| It is noise | The step down does not repeat in a second rotation run |

### Results of the probe

```
tag        scan/10s     point/10s    cpu_mhz      temp_c     vault_lines/s  server_cpu_s/s idle%      iowait%
(each cell is: mean before the second key version / mean after it)
control1   155/158      634/649      2016.4/2002.6 63.2/62.7  0.33/0.42      5.09/5.17      38/38      0/0
rotate1    156/157      636/644      2031.2/2006.0 62.8/62.3  0.40/0.35      5.07/5.15      38/37      0/0
control2   158/161      649/662      2046.0/2043.6 62.4/62.6  0.33/0.44      5.15/5.16      38/38      0/0
rotate2    158/162      652/667      2015.2/2037.9 63.2/62.3  0.42/0.35      5.15/5.15      39/39      0/0
```

**The step down did not repeat.** In both rotation runs the scan and point throughput after the second new key version is the same as before it (156 to 157 and 158 to 162 scan rounds per 10 s), exactly like in the controls. Not one signal changed after the second key version:

- **Clock speed and temperature:** about 2.0 GHz and 62 to 63 °C in every run, before and after.
- **Vault requests:** 0.33 to 0.44 log lines per second in every run. There was no jump after the new versions.
- **Server CPU:** about 5.1 CPU seconds per second (5 busy cores), idle 37 to 39%, iowait 0, in every run.
- **InnoDB's key request counter:** it rose by 50.0 to 51.3 million in each 240 s run (about 210,000 per second), with and without rotation. The rotation runs made 1 to 2% fewer requests, which matches the small difference in work done.

### What we think happened in the first run

We do not know. The first run's step down is not an effect of the rotation, because it did not come back in two more rotations. What stands out is its first minute: 173 scan rounds per 10 s, which is 10 to 12% more than the first minute of any other run (154 to 158). After the second key version it was at 150, which is 5 to 7% below the others (157 to 162). So it looks more like an unusually fast first minute than a slow second part. We did not record clock speed in that run, so we cannot check whether the laptop was running faster at the start. This fits what the sysbench runs showed: the first run of a series is often the fastest, and the laptop settles after about 25 s. But the later runs started after a 60 s pause and did not show a fast start at all, so we cannot explain it fully.

### Limits of the probe

- Four runs on one laptop, one rotation scenario (key 2, two new versions 40 s apart), and one load.
- The probe runs started from key 2 tables that had already been re-encrypted at least once. The first run started from version 1.
- The signals are means over 5 s samples. A short event that lasted less than 5 s would not show up.
- Vault's audit log was on during the four probe runs but not during the first run and its control, which could slightly change Vault's side of a request. The server side is unaffected.

### Files of the probe

`results/claudia2/probe/` holds the four runs: `control1`, `rotate1`, `control2` and `rotate2` each have a folder with `rotation_events.txt`, `rotation_progress.txt` and `rotation_summary.txt`. Next to each folder there are `<run>_samples.tsv` (clock, temperature, Vault log lines, server CPU), `<run>_vmstat.txt` and `<run>_status.tsv` (InnoDB's encryption counters every 5 s).
