# The Linux Server Saturation Runbook — CPU · Memory · Disk

**A process-driven guide to diagnosing a struggling server: classify the problem, confirm the cause, separate real issues from false positives — with real command output at every step.**

High load average is usually the symptom that sends you here, but load is just a pointer. This runbook walks you from that pointer to the actual resource — **CPU, memory, or disk** — and gives each one a complete, self-contained playbook. Every command reports in **GB or MB**; tools that only emit KB (`/proc/meminfo`, `ps`, `pidstat`) are wrapped in `awk` so you never divide by 1024 by hand.

---

## How to use this guide

1. Read **Section 1** once — the mental model that prevents most misdiagnosis.
2. On a hot box, run **Phase 0** (Section 3) and the **60-second classifier** (Section 4). Together they tell you whether you have a CPU, memory, disk, or *no* problem.
3. Jump to the matching playbook: **Part A — CPU** (§5), **Part B — Memory** (§6), **Part C — Disk/IO** (§7).
4. Each diagnostic shows the output, then labels it **HEALTHY / FALSE POSITIVE** or **REAL PROBLEM**.
5. Keep the **snapshot script** (§9) for one-screen capture during an incident.

---

## 1. Mental model

### 1.1 Load average is a pointer, not a verdict
Load = moving average of `nr_running` (tasks in **R**, wanting CPU) **+** `nr_uninterruptible` (tasks in **D**, blocked on I/O). So a high number can mean CPU demand, I/O blocking, or both — and it lags, staying high after the cause is gone. **Always normalize against `nproc`:** load 35 on 32 cores is ~1.1× (mild); on 8 cores it's ~4.4× (serious).

### 1.2 "Used" is not "pressure"
For memory, `sar`/`free` count reclaimable page cache as "used." The truth is **`MemAvailable`**. For disk, `%util` near 100% on an SSD/NVMe does **not** mean saturated. For CPU, high load with low `%us` often means the CPU isn't the problem at all.

### 1.3 The golden rule
> **Classify, confirm, then confirm impact.** Identify the resource, prove it's the bottleneck with a second independent metric, and check whether it's actually hurting anything. Skipping the middle step is how cache accounting, CPU steal, and stale spikes get mistaken for incidents.

---

## 2. Master decision tree

```
SERVER STRUGGLING / HIGH LOAD
│
├─ Phase 0: load vs nproc? trend rising/flat/falling? bare metal or VM?     (§3)
│      falling fast + tiny run queue ───────────────────► STALE SPIKE      (§8)
│
├─ 60-second classifier: vmstat + free + iostat in one look                (§4)
│      │
│      ├─ cpu block hot (us/sy high, st low, wa low) ───► PART A: CPU       (§5)
│      ├─ st (steal) high on a VM ──────────────────────► CPU §5.6 (impostor)
│      ├─ available low / si/so moving ─────────────────► PART B: MEMORY    (§6)
│      ├─ b high / wa high / PSI io high ───────────────► PART C: DISK/IO   (§7)
│      └─ everything calm but load high ────────────────► STALE / §5.5 threads
│
└─ Confirm with the resource's second metric, then check impact & remediate.
```

---

## 3. Phase 0 — Orient (always first)

```bash
uptime
nproc                          # logical CPUs (the number load is measured against)
lscpu | grep -E '^CPU\(s\)|Core|Socket|Thread'   # physical cores vs threads
cat /proc/loadavg
systemd-detect-virt            # 'none' = bare metal; else a VM (steal is in play)
```
```
$ uptime
 14:32:07 up 47 days,  3:11,  4 users,  load average: 35.18, 22.04, 14.76
$ cat /proc/loadavg
35.18 22.04 14.76 2/1841 884213
                   │   │
                   │   └─ total tasks
                   └───── tasks runnable RIGHT NOW
```
**REAL (live):** the three averages are flat or rising AND "runnable now" is large (e.g. `30/1841`). → §4.
**FALSE POSITIVE (stale):** averages fall left→right (`35/22/14`) AND "runnable now" is tiny (`2/1841`). The event already ended. → §8.

> **Hyperthreading note:** `nproc` counts logical threads. If `lscpu` shows 16 cores / 32 threads, the second thread per core isn't a full CPU — so saturation can appear before load reaches the logical count. Judge against physical cores when load is borderline.

---

## 4. The 60-second classifier

Three commands tell you which resource is the problem.

```bash
vmstat -S M 1 5      # -S M => memory/swap columns in MiB
free -h              # look at the AVAILABLE column
iostat -xm 1 3       # -m => MB/s; -x => %util/await/queue
```

**`vmstat` is the dispatcher** — read its columns in this order:

```
 r  b   swpd  free  buff  cache   si  so   bi    bo    in    cs  us sy id wa st
```
- **`st`** (steal) high → VM impostor → §5.6
- **`wa`** high and/or **`b`** high → disk/IO → **Part C**
- **`si`/`so`** moving → memory pressure/paging → **Part B**
- **`us`/`sy`** high, `st`/`wa` low → CPU → **Part A**
- all calm, `id` high, but load high → stale (§8) or hidden threads (§5.5)

The fastest cross-check is **PSI** (kernel ≥ 4.20), already in percent-stalled:
```bash
for r in cpu io memory; do echo "== $r =="; cat /proc/pressure/$r; done
```
```
== io ==
some avg10=78.43 avg60=71.20 avg300=55.66 total=98342111   <- 78% of last 10s stalled on I/O
```
Whichever of cpu/io/memory lights up sends you straight to that part.

---

# PART A — CPU

## 5.1 When to suspect CPU

`vmstat` cpu block shows high **`us`** (userspace) or **`sy`** (kernel), low `wa`/`st`, `id` near 0, and **`r` > cores**. PSI `cpu` elevated.

## 5.2 Confirm: per-core spread vs. pinning

```bash
mpstat -P ALL 1 3
```
**REAL PROBLEM — genuine demand (all cores hot):**
```
CPU    %usr  %sys  %iowait  %steal  %idle
all    91.0   6.2     0.1     0.0     2.7
  0    92.0   6.0     0.0     0.0     2.0
  ...  (all 32 cores 88–93% busy)
```
Every core saturated → real CPU demand. Profile the top consumer, scale out, or add cores.

**Diagnostic nuance — one core pinned, rest idle:**
```
CPU    %usr  %sys  %iowait  %idle
all     3.1   0.9     0.0    95.8
  0    99.0   1.0     0.0     0.0     <- single-threaded hot path
  1     0.5   0.2     0.0    99.3
```
A single hot thread can't move a 32-core load average much by itself — but if work serializes behind it, queues build. Adding cores won't help; the fix is in the code path.

## 5.3 Confirm: which process, averaged (beats top's flicker)

```bash
pidstat -u 1 5      # %CPU per process over 5s; can exceed 100 across cores
```
```
Average:   UID   PID    %usr  %system   %CPU  Command
Average:  1000  4123   780.2    42.1   822.3  java        <- ~8 cores' worth
Average:     0  9981     3.0     1.2     4.2  node
```

## 5.4 Attribute to threads (the "nothing in top" case)

`top` hides threads by default. A pool (JVM, DB, goroutines) spreads load thin.
```bash
top -H -E g -e m                          # thread view; summary GB, task mem MB
ps -eo pid,nlwp,comm --sort=-nlwp | head  # who owns the most threads
pidstat -t -p <PID> 1 5                   # per-thread %CPU
```
```
   PID NLWP COMMAND
  4123  214 java        <- 214 threads, each ~3% => fills the run queue invisibly
  3380   48 postgres
```

## 5.5 Attribute to fork churn (the sampling blind spot)

Thousands of short-lived processes die faster than `top` refreshes. **Tells:** high `cs` and `in` in `vmstat`, persistently high `r`, nothing steady in `top`.
```bash
sudo execsnoop-bpfcc        # trace every exec() live (bcc/bpfcc-tools)
sudo atop 1                 # flags exited processes
```
```
$ sudo execsnoop-bpfcc
PCOMM      PID    PPID   RET ARGS
sh         21031  4001     0 /bin/sh -c /usr/local/bin/healthcheck
curl       21033  21032    0 /usr/bin/curl -s localhost:8080/health
sh         21041  4001     0 /bin/sh -c /usr/local/bin/healthcheck   <- repeating every few ms
```
Find the source: `systemctl list-timers --all` and `journalctl -p warning -S "10 min ago"` (crash-loops surface here).

## 5.6 CPU impostors (high load, but not your CPU problem)

**VM CPU steal** — hypervisor took your cycles:
```bash
mpstat -P ALL 1 3      # watch %steal
```
```
CPU    %usr  %sys  %steal  %idle
all    40.1   7.2    48.0    4.4      <- 48% stolen; your guest is barely scheduled
```
**REAL but not on-box:** resize/move the instance or escalate to the provider. Don't profile the app — it isn't running.

**cgroup CPU throttling** (containers) — CPU% looks fine but quota throttles you:
```bash
cat /sys/fs/cgroup/cpu.stat              # v2
cat /sys/fs/cgroup/cpu/cpu.stat          # v1
```
```
nr_periods     1820342
nr_throttled   1640220        <- throttled in ~90% of periods
throttled_usec 882001000
```
Rising `nr_throttled` → raise the limit (`--cpus` / `cpu.max` / k8s `limits.cpu`) or cut concurrency. The host has CPU; your cgroup isn't allowed to use it.

**IRQ / softirq storm** — a core buried in interrupts (flaky NIC/driver):
```bash
mpstat -P ALL 1 3      # look at %irq and %soft
```
```
CPU    %usr  %sys  %soft  %idle
  3     1.0   2.0   88.0    9.0       <- core 3 drowning in softirqs
```
Check NIC errors (`ethtool -S`), spread RPS/RSS, update the driver.

## 5.7 CPU: problem vs. false positive

| Signal | FALSE POSITIVE / benign | REAL PROBLEM |
|---|---|---|
| Load vs nproc | ≤ ~1×, falling | > 1×, flat/rising |
| `us`+`sy` | low; `id` high | high; `id` ~0 |
| `st` (VM) | 0 | significant (steal) |
| `nr_throttled` | flat | rising (quota too tight) |
| `r` | ≤ cores | persistently > cores |
| mpstat shape | brief/one-core | all cores hot, sustained |
| High load + low `us` | look at wa/st/b instead | — |

---

# PART B — MEMORY

## 6.1 When to suspect memory

`free` shows tiny **available** (not just high "used"), or `vmstat` shows **`si`/`so`** moving, or PSI `memory` elevated, or the OOM killer fired.

## 6.2 The one screen that settles "used vs. pressure"

```bash
free -h            # AVAILABLE is the truth, not used
free -m            # same, in MB
```
**FALSE POSITIVE — it's page cache:**
```
               total        used        free      shared  buff/cache   available
Mem:           125Gi        48Gi       2.1Gi       1.2Gi        75Gi        70Gi
Swap:           32Gi       4.0Gi        28Gi
```
`used 48Gi` and `free 2.1Gi` look alarming, but `available 70Gi` + `buff/cache 75Gi` = 75 GB reclaimable cache. **No pressure.** The 4 GB swap is leftover (confirm it's static — §6.6).

**REAL PROBLEM — genuine exhaustion:**
```
               total        used        free      shared  buff/cache   available
Mem:           125Gi       119Gi       1.8Gi       0.4Gi        3.9Gi       2.1Gi
Swap:           32Gi        31Gi       1.0Gi
```
`available 2.1Gi`, swap nearly full → real pressure, OOM risk.

## 6.3 Detailed breakdown, in GB

```bash
awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Shmem|Slab|SReclaimable|SUnreclaim|AnonPages|Mapped|PageTables):/ \
  {printf "%-16s %8.2f GB\n", $1, $2/1048576}' /proc/meminfo
```
```
MemTotal           125.55 GB
MemAvailable        70.31 GB    <- real headroom
Cached              73.40 GB    <- reclaimable; this IS your "used"
Shmem                1.20 GB    <- tmpfs/shared; NOT in any process RSS
SUnreclaim           1.80 GB    <- kernel memory you can't reclaim
AnonPages           41.02 GB    <- real process memory
```
- **Shmem** large → tmpfs holding memory invisible to `ps` (§6.5).
- **SUnreclaim** large (many GB) → a **kernel/driver** leak, not an app.

## 6.4 Prove processes don't account for "used", and find the real growth

```bash
ps -eo rss --no-headers | awk '{s+=$1} END {printf "Sum of all RSS: %.2f GB\n", s/1048576}'
ps -eo pid,user,rss,comm --sort=-rss | \
  awk 'NR==1{printf "%-8s %-10s %10s  %s\n","PID","USER","RSS(MB)","COMMAND";next}
       NR<=11{printf "%-8s %-10s %10.1f  %s\n",$1,$2,$3/1024,$4}'
```
```
Sum of all RSS: 44.10 GB
PID      USER            RSS(MB)  COMMAND
4123     app             8201.4   java
3380     postgres        6105.2   postgres
```
If the RSS sum is far below "used," the gap is cache/Shmem/slab → **nothing hiding in a process.**

> **Caveat:** RSS double-counts shared libraries across processes, so it *overstates*. For true footprint use **PSS** (proportional set size):
> ```bash
> sudo smem -t -k -c "pid user pss rss command" | tail -15   # PSS divides shared pages; -k shows K/M/G suffixes
> ```

## 6.5 Find invisible memory (tmpfs / Shmem)

```bash
df -h -t tmpfs
du -sh /dev/shm /tmp /run 2>/dev/null
```
```
Filesystem      Size  Used Avail Use% Mounted on
tmpfs            63G   18G   45G  29% /dev/shm     <- 18 GB used, never shows in ps
```

## 6.6 Is swap actually doing anything?

```bash
vmstat -S M 1 5      # watch si/so (MB/s)
```
- `si/so ≈ 0` → swap is **inert**; in-use swap is leftover from a past spike or NUMA. **FALSE POSITIVE.**
- Sustained `si/so` → **REAL PROBLEM:** active paging under pressure.

Cosmetic cleanup, only after confirming RAM free and `si/so=0`:
```bash
# sudo swapoff -a && sudo swapon -a
```

## 6.7 Did the OOM killer fire? (memory's smoking gun)

```bash
dmesg -T | grep -iE 'killed process|out of memory|oom' | tail
journalctl -k -S "today" | grep -i oom
# per-cgroup OOM count (v2):
cat /sys/fs/cgroup/memory.events 2>/dev/null
```
```
$ dmesg -T | grep -i 'killed process'
[Tue Jun  9 13:58:11 2026] Out of memory: Killed process 4123 (java) total-vm:88200000kB, anon-rss:81000000kB
```
An OOM kill is unambiguous **REAL PROBLEM** — something genuinely exhausted RAM (or a cgroup limit). Right-size the workload or the limit.

## 6.8 NUMA imbalance (totals fine, one node starved)

`numastat -m` reports in **MB**:
```bash
numactl -H
numastat -m | sed -n '1,15p'
```
```
$ numactl -H
node 0 free:   900 MB        <- starved
node 1 free: 38000 MB        <- plenty
```
Lopsided free + local reclaim → **REAL PROBLEM:** pin/rebalance (`numactl`/`numad`) or check `vm.zone_reclaim_mode`.

## 6.9 Memory: problem vs. false positive

| Signal | FALSE POSITIVE / benign | REAL PROBLEM |
|---|---|---|
| "used" 95% | `MemAvailable` large | `MemAvailable` tiny |
| buff/cache large | yes (reclaimable) | n/a |
| swap in use | static, `si/so=0` | `si/so` sustained |
| RSS sum vs used | RSS ≪ used (cache) | RSS ≈ used (real growth) |
| Shmem/tmpfs | expected app usage | runaway, fills RAM |
| OOM log | none | "Killed process …" present |
| PSI memory | ~0 | tens of % |

---

# PART C — DISK / I/O

> **Two different problems wear the "disk" label: running out of *space* (capacity) and running out of *throughput/latency* (I/O). Diagnose them separately.**

## 7.1 When to suspect disk I/O

`vmstat` shows **`b` > 0** and **`wa`** high, PSI `io` elevated, tasks in **D** state. (Capacity problems instead show as `ENOSPC` errors, failed writes, or apps crashing — not load.)

## 7.2 I/O: which tasks are blocked, and where

```bash
ps -eo state,pid,ppid,wchan:28,comm | awk 'NR==1 || $1 ~ /^D/'
```
```
S    PID  PPID WCHAN                    COMMAND
D   9001     1 io_schedule              postgres        <- local block I/O
D   8821  8800 nfs_wait_bit_killable    rsync           <- network filesystem
```
`io_schedule`/`wait_on_page_bit`/`blk_*` = local disk. `nfs_*`/`rpc_*` = network filesystem (the local disk may be idle — §7.6).

## 7.3 I/O: which device is saturated — in MB/s

```bash
iostat -xm 1 3       # -m => MB/s
```
**HEALTHY:**
```
Device   r/s    w/s   rMB/s  wMB/s  r_await  w_await  aqu-sz  %util
nvme0n1  12.0   45.0   0.40   1.10    0.22     0.51     0.03    1.8
```
**REAL PROBLEM (spinning disk / SATA):**
```
Device   r/s     w/s    rMB/s  wMB/s  r_await  w_await  aqu-sz  %util
sdb      210.0   980.0   3.20   88.0    45.6    120.3    34.2    99.4
```
`%util 99`, `aqu-sz 34` (deep queue), `w_await 120ms` → saturated. Find the writer (§7.4).

> **CRITICAL false-positive trap — `%util` on SSD/NVMe.** `%util` measures *time with ≥1 I/O in flight*, not how busy a parallel device is. A multi-queue NVMe drive routinely shows **`%util` near 100% with huge headroom remaining**. On SSD/NVMe, **ignore `%util`** and judge by: `await`/latency (is it rising under load?), actual `rMB/s`+`wMB/s` vs the drive's rated throughput, and whether `aqu-sz` keeps climbing. High `%util` alone on NVMe is **not** a problem.

## 7.4 I/O: blame the process

```bash
sudo iotop -oPa            # -o active, -P per-process, -a accumulated (best if installed)
pidstat -d 1 5             # per-process disk; kB/s — divide by 1024 for MB/s
```
```
$ sudo iotop -oPa
  PID  USER      DISK READ   DISK WRITE   COMMAND
 9001  postgres   0.00 B      4.20 GB     postgres: autovacuum
 8821  backup     1.10 GB     0.00 B      rsync -a /data /mnt/nfs
```

## 7.5 Capacity: "disk full" — and its three classic false leads

```bash
df -h                      # space, human-readable
df -BG                     # space, whole GB
df -ih                     # INODES — a full-but-not-really case
```
**Case 1 — genuinely full:**
```
$ df -h /data
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1       500G  500G   20K 100% /data
```
Find the space:
```bash
du -xh /data --max-depth=1 2>/dev/null | sort -rh | head    # -x stays on one filesystem
```

**Case 2 — FALSE "full": inodes exhausted, space free:**
```
$ df -h /data ;  df -ih /data
/dev/sdb1  500G  120G  380G  24% /data          <- space looks fine
/dev/sdb1  IUse% 100%  IFree 0                   <- but no inodes left
```
Millions of tiny files. `du` won't show big dirs; hunt file *counts*:
```bash
for d in /data/*; do printf "%8s  %s\n" "$(find "$d" 2>/dev/null | wc -l)" "$d"; done | sort -rn | head
```

**Case 3 — FALSE "full": `df` says full but `du` doesn't add up — deleted-but-open files:**
A process holds a deleted file open, so the space isn't freed until it closes.
```bash
sudo lsof +L1 | awk 'NR==1 || $7+0 > 100000000'   # open files with link count 0; size col in bytes
```
```
COMMAND   PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NLINK  NODE  NAME
java     4123  app   12  REG   253,1   42000000000  0  98231  /var/log/app.log (deleted)
```
A 42 GB deleted-but-open log → restart (or signal) the holding process to reclaim the space. **This is the #1 "I deleted files but df didn't change" mystery.**

## 7.6 I/O impostors and hardware faults

**High iowait, idle local disks → it's the network filesystem:**
```bash
mount | grep -E 'nfs|cifs'
nfsstat -c                 # high 'retrans' = server/network trouble
```
A slow NFS server pins clients in **D** with zero local disk activity — the fix is server-side.

**Filesystem went read-only / device errors (silent app failures):**
```bash
dmesg -T | grep -iE 'error|i/o error|remount.*read-only|ext4|xfs|nvme|ata' | tail
mount | grep -w ro         # an unexpectedly read-only mount
```

**Drive health (failing disk = rising latency, retries):**
```bash
sudo smartctl -H /dev/sda
sudo smartctl -A /dev/sda | grep -iE 'reallocated|pending|crc|wear'
```

## 7.7 Disk: problem vs. false positive

| Signal | FALSE POSITIVE / benign | REAL PROBLEM |
|---|---|---|
| `%util` 100% on NVMe/SSD | yes — meaningless there | n/a (use await instead) |
| `%util` 100% on HDD/SATA | brief bursts | sustained + deep `aqu-sz` |
| `await`/latency | flat under load | rising sharply under load |
| High `wa`, idle local disk | NFS/network FS | local device saturated |
| `df` 100% full | inodes ok, no deleted-open | genuinely out of space |
| df≠du discrepancy | — | deleted-but-open files (lsof +L1) |
| `df -i` 100% | n/a | inode exhaustion (tiny files) |
| SMART | PASSED, no reallocations | failing / reallocated sectors |

---

## 8. The stale spike (the most common false positive of all)

Phase 0 showed load **falling** with a small "runnable now." The event is over — find *what* spiked, expect no live culprit.
```bash
sar -q | tail -30      # runq-sz + load over the day
sar -u | tail -30      # CPU
sar -r | tail -30      # memory (%memused counts cache)
sar -b | tail -30      # I/O transfer rate
sar -W | tail -30      # swapping
```
```
$ sar -q | tail -4
14:10:01   runq-sz  plist-sz  ldavg-1  ldavg-5  ldavg-15
14:10:01        34      1820    33.90    20.10    12.40   <- spike
14:20:01         1      1790     1.10     6.20     9.80   <- recovered
```
Correlate the timestamp:
```bash
systemctl list-timers --all
journalctl -S "today" --no-pager | grep -iE 'backup|reindex|vacuum|compact|gc|cron' | tail
```
A backup, log rotation, DB vacuum, or batch job that briefly fills the run queue is **benign**. Note it, tune the alert to ignore short excursions, move on.

---

## 9. One-shot snapshot script (CPU + memory + disk, all GB/MB)

Save as `~/saturation-snap.sh`, `chmod +x`, run during an incident.

```bash
#!/usr/bin/env bash
# saturation-snap.sh — one-screen CPU/memory/disk triage, all values in GB/MB
echo "===== $(date) — $(hostname) — virt:$(systemd-detect-virt 2>/dev/null) ====="
echo "logical CPUs: $(nproc)"
echo "loadavg (1 5 15  runnable/total): $(cat /proc/loadavg)"

echo; echo "== CPU =="
vmstat -S M 1 2 | tail -1 | \
  awk '{printf "  r=%s b=%s | us=%s sy=%s id=%s wa=%s st=%s | cs=%s/s in=%s/s\n",$1,$2,$13,$14,$15,$16,$17,$12,$11}'
echo "  -- top 5 by CPU --"
pidstat -u 1 1 2>/dev/null | awk '/Average:/ && $8!="Command" {printf "  %-8s %6.1f%%CPU  %s\n",$3,$7,$9}' | sort -k2 -rn | head -5
echo "  -- top 5 by thread count --"
ps -eo pid,nlwp,comm --sort=-nlwp | awk 'NR>1 && NR<=6 {printf "  %-8s %5s thr  %s\n",$1,$2,$3}'
for r in cpu io memory; do printf "  PSI %-7s %s\n" "$r" "$(awk '/some/{print}' /proc/pressure/$r 2>/dev/null)"; done

echo; echo "== MEMORY (GB) =="
awk '/^(MemTotal|MemAvailable|Cached|Shmem|SUnreclaim|AnonPages|SwapTotal|SwapFree):/ \
  {printf "  %-14s %8.2f GB\n",$1,$2/1048576}' /proc/meminfo
ps -eo rss --no-headers | awk '{s+=$1} END {printf "  process RSS total: %.2f GB\n", s/1048576}'
echo "  -- top 5 by RSS (MB) --"
ps -eo pid,rss,comm --sort=-rss | awk 'NR>1 && NR<=6 {printf "  %-8s %9.1f MB  %s\n",$1,$2/1024,$3}'
echo "  -- recent OOM kills --"
dmesg -T 2>/dev/null | grep -i 'killed process' | tail -3 | sed 's/^/  /' || echo "  (dmesg needs root)"

echo; echo "== DISK =="
echo "  -- space (GB) --"
df -BG -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR==1 || $5+0>80 {printf "  %s\n",$0}'
echo "  -- inodes >80% --"
df -i 2>/dev/null | awk 'NR>1 && $5+0>80 {printf "  %-20s IUse=%s\n",$6,$5}'
echo "  -- device I/O (MB/s, util) --"
iostat -xm 1 2 2>/dev/null | awk '/^[a-z]/ && $NF+0>1 {printf "  %-10s r=%.1f w=%.1f MB/s  await(r/w)=%.1f/%.1f  aqu=%.1f  util=%.1f%%\n",$1,$3,$4,$10,$11,$(NF-1),$NF}' | tail -6
echo "  -- tasks in D --"
ps -eo state,pid,wchan:24,comm | awk '$1 ~ /^D/ {printf "  D %-7s %-24s %s\n",$2,$3,$4}'
ps -eo state --no-headers | grep -q '^D' || echo "  (none)"
```

---

## 10. Master problem-vs-false-positive table

| Resource | Looks scary but FINE when… | Genuinely a PROBLEM when… |
|---|---|---|
| **Load** | falling, run queue now small, ≤1× cores | flat/rising, >1× cores, large run queue |
| **CPU** | high load but low `us`; brief one-core spike | all cores hot sustained; `r`≫cores |
| **CPU (VM)** | — | high `st` (steal) — escalate to provider |
| **CPU (container)** | — | rising `nr_throttled` — quota too tight |
| **Memory** | "used" 95% but `MemAvailable` large; static swap | `MemAvailable` tiny; `si/so` moving; OOM kills |
| **Memory** | RSS sum ≪ used (cache); big buff/cache | RSS sum ≈ used (real growth); big Shmem leak |
| **Disk I/O** | `%util` 100% on NVMe; high `wa` w/ idle local disk (NFS) | sustained `%util` on HDD + deep queue; rising `await` |
| **Disk space** | df≠du (deleted-open files, recoverable); — | truly 100% full; inodes 100%; SMART failing |

---

## 11. Unit cheat-sheet

| Tool | Native unit | Get GB/MB |
|---|---|---|
| `free` | KiB | `free -h` (auto) · `free -m` (MB) · `free -g` (GB) |
| `/proc/meminfo` | KB | `awk '{$2/1048576}'` → GB |
| `vmstat` | KB mem cols | `vmstat -S M` → MiB |
| `iostat` | KB/s | `iostat -xm` → MB/s |
| `ps` (rss/vsz) | KB | `awk '$col/1024'` → MB |
| `pidstat -d` | kB/s | ÷1024 → MB/s (or use `iostat -xm`) |
| `df` | KB blocks | `df -h` (auto) · `df -BM` (MB) · `df -BG` (GB) |
| `du` | KB | `du -h` (auto) · `du -BM` (MB) |
| `smem` | bytes | `smem -k` → K/M/G suffixes |
| `numastat -m` | MB | already MB |
| `top` | mixed | `top -E g -e m` (summary GB, tasks MB) |
| `lsof` size | bytes | divide by 1073741824 → GB |
| `/proc/pressure/*`, `cpu.stat` | % / µs | no conversion |

---

## 12. Glossary

- **R-state / runnable** — ready to run, waiting for a CPU. The "demand" half of load.
- **D-state / uninterruptible sleep** — blocked in the kernel, almost always on I/O; can't be killed normally. The "blocked" half of load.
- **wchan** — kernel function a sleeping task is parked in; names the subsystem it waits on.
- **MemAvailable** — usable memory without swapping; the real headroom figure.
- **PSS** — proportional set size; RSS with shared pages divided across sharers (truer footprint than RSS).
- **Steal (`st`)** — CPU time the hypervisor gave to other guests; only meaningful on VMs.
- **PSI** — Pressure Stall Information (`/proc/pressure/*`); % of time tasks stalled on cpu/io/memory.
- **CFS throttling** — scheduler enforcing a cgroup CPU quota; throttled tasks stay runnable, inflating load.
- **`%util` (iostat)** — % of time the device had ≥1 I/O in flight. Meaningful on single-queue HDD; **misleading on parallel SSD/NVMe**.
- **aqu-sz** — average I/O queue depth; a rising queue is a better saturation signal than `%util`.
- **Deleted-but-open file** — a file unlinked while still held open; its space isn't freed until the holder closes it (`lsof +L1`).
- **Page cache / buff/cache** — reclaimable RAM holding file data; counted as "used" but free for the taking.
```
