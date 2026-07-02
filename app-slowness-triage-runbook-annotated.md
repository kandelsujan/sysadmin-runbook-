# "The App Is Running Slow" — Full-Toolkit Triage Runbook (Annotated Edition)

Same runbook as before, now with example outputs for every command, annotated with **what a real problem looks like**, **what's a red herring**, and — at the end — **exactly what to hand the dev team** so they can run their side of the investigation in parallel instead of waiting on you.

Division of labor reminder:
- **`sar`** = time machine (historical / recurring windows)
- **Live tools** = right-now, per-process detail `sar` can't give you
- **Logs** (`dmesg`, `journalctl`) = discrete events (OOM kills, disk errors) that turn counter patterns into named causes

First fork: **is it slow right now, or was it slow earlier?**

---

## Step 0: Context First

Ask the dev team: when exactly, what specifically is slow (everything vs. certain endpoints), and what changed recently (deploy/config/traffic/batch job). Then baseline the hardware:

```bash
$ nproc
8
$ free -h
               total   used   free   shared  buff/cache  available
Mem:            31Gi   12Gi   1.2Gi   0.5Gi       18Gi        18Gi
Swap:          4.0Gi   256Mi  3.7Gi
$ uptime
 14:22:31 up 41 days,  3:02,  2 users,  load average: 9.84, 8.10, 4.22
```

**Reading this trio:**
- 8 cores → every load/runq number below gets judged against **8**.
- `free` shows 1.2Gi "free" — **red herring if read alone**; `available` = 18Gi is the real number (see memory guide). 256Mi sitting in swap with no active swapping is also **not** by itself a problem — could be old cold pages.
- `uptime`: 1-min load (9.84) > 5-min (8.10) > 15-min (4.22) → the problem is **building right now**, not steady-state. If instead 15-min were the highest, you'd be looking at something already recovering.
- 41 days uptime → rules out "it just rebooted"; also means slow leaks have had time to accumulate.

**Red herring at this stage:** load 9.84 on 8 cores looks scary, but you don't yet know if it's CPU demand or blocked-on-I/O processes — do **not** conclude anything from load alone (load guide, §3).

---

## Path A: Slow RIGHT NOW

### A1. `dmesg -T | tail -30` — free root causes

**What a real problem looks like (OOM kill):**
```
[Tue Jul  1 14:17:02 2026] Out of memory: Killed process 31337 (java) total-vm:18563024kB, anon-rss:14892340kB
[Tue Jul  1 14:17:02 2026] oom_reaper: reaped process 31337 (java)
```
Case basically closed — a 14GB java process got killed 5 minutes ago. The "slowness" is likely the app restarting/degraded plus the memory pressure leading up to it. Confirm the ramp with `sar -r`/`-W` (Path B commands) for the preceding hour.

**What a real problem looks like (disk):**
```
[Tue Jul  1 14:10:44 2026] blk_update_request: I/O error, dev sda, sector 812736512 op 0x0:(READ)
[Tue Jul  1 14:10:47 2026] EXT4-fs warning (device sda1): ext4_end_bio:343: I/O error 10 writing to inode 5242891
```
Failing disk. Every retried read stalls whatever's waiting on it. This goes to whoever owns hardware/storage, not the dev team.

**Red herring:**
```
[Tue Jul  1 09:03:11 2026] perf: interrupt took too long (2513 > 2500), lowering kernel.perf_event_max_sample_rate
[Mon Jun 30 22:15:40 2026] TCP: request_sock_TCP: Possible SYN flooding on port 8080. Sending cookies.
```
The `perf` message is routine self-tuning noise. The SYN-flood message *can* matter, but check the timestamp — this one is from **last night**, not your current window. Stale scary-looking dmesg lines with the wrong timestamp are one of the most common wild-goose chases; always check the `-T` timestamps against the reported window.

---

### A2. `vmstat 1 5` — the five-resource X-ray

```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 2  9 262144 1240000 130000 18400000  0  480   120 42000 8000 9500 12  8 15 65  0
 3  8 262144 1180000 130000 18350000  0  512    80 45000 8200 9800 10  9 14 67  0
 1 10 262144 1150000 130000 18300000  0  505   100 43800 8100 9600 11  8 13 68  0
```

**What this real problem looks like:** `so` (swap-out) sustained ~500/s across every sample, `b` (blocked) at 8–10 while `r` (runnable) is only 1–3, `wa` (iowait) at ~65%. Translation: this is **memory pressure driving disk I/O** — processes aren't fighting for CPU (`r` is tiny vs. 8 cores), they're blocked waiting on swap traffic. The load of 9.84 from Step 0 is now explained: it's the `b` column, not CPU demand.

**Red herring version of the same report:**
```
 r  b swpd    free    buff   cache  si   so   bi    bo    in    cs us sy id wa st
 9  0 262144 1240000 130000 18400000  0    0  200  1800  6000 12000 88  9  3  0  0
```
`r` = 9 on 8 cores with `us` at 88% — CPU is fully busy and there's a small queue. **This may be completely fine**: a well-parallelized compute job using the hardware as intended. `r` hovering right around core count with high `%us` and *no* growth trend is legitimate full utilization, not a fire. It's a problem only if it's sustained well above core count AND the app's latency actually correlates. Also note `swpd` = 262144 (256MB in swap) with `si`/`so` = 0 — swap *occupancy* without swap *activity* is leftover cold pages, not current pressure (memory guide, §6).

**First-sample gotcha:** `vmstat`'s very first output line is an average since boot, not current — always ignore line 1 and read from the second sample onward.

---

### A3. `mpstat -P ALL 1 3` — per-core balance

**What a real problem looks like:**
```
14:23:01  CPU  %usr  %nice  %sys  %iowait  %irq  %soft  %steal  %idle
14:23:02  all  13.1   0.0    2.4     0.5    0.0    1.2     0.0   82.8
14:23:02    0  99.0   0.0    1.0     0.0    0.0    0.0     0.0    0.0
14:23:02    1   1.9   0.0    2.1     0.9    0.0    0.8     0.0   94.3
14:23:02    2   2.2   0.0    3.0     0.4    0.0    0.6     0.0   93.8
...
```
Aggregate looks idle (82.8%) — but CPU 0 is pegged at 99% `%usr`. Classic **single-thread bottleneck**: the app has one hot thread (main event loop, GC thread, a serialized lock holder) and adding cores won't help. This is prime dev-team handoff material (see the handoff section — they need to know *which thread*, which `pidstat -t` will give you).

**The other real problem this catches:**
```
14:23:02    3   2.0   0.0    5.1     0.2    0.4   88.9     0.0    3.4
```
One core at ~89% `%soft` (softirq) → all network interrupt processing pinned to one core. That core becomes the ceiling for the whole NIC's throughput. Check `cat /proc/interrupts` and whether `irqbalance` is running. Infra-side fix, not app-side.

**Red herring:**
```
14:23:02  all  71.0   0.0   11.2     1.1    0.2    2.5     0.0   14.0
(all 8 cores individually between 65-78% usr)
```
High but *even* utilization across all cores = a healthy parallel workload at ~70%. Nothing to fix. The issue is imbalance or saturation-with-symptoms, never "big number" alone.

**Cloud-specific real problem:**
```
14:23:02  all  22.0   0.0    6.0     1.0    0.0    1.0    31.0   39.0
```
`%steal` at 31% sustained = the hypervisor is giving nearly a third of your cycles to someone else. Nothing inside the guest fixes this; escalate/resize/move instance (CPU guide §3). **Red herring version:** a single 1-second sample showing steal at 4–8% that vanishes next sample — routine scheduling jitter, ignore.

---

### A4. `iostat -xz 1 3` — storage reality check

**What a real problem looks like:**
```
Device   r/s    w/s    rkB/s   wkB/s  rrqm/s wrqm/s  %rrqm %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
sda      2.0  418.0     64.0 42800.0    0.0   105.0    0.0  20.1    3.10  187.40   28.40    32.0    102.4   2.30  99.60
```
`w_await` = 187ms against an SSD baseline of a few ms, `aqu-sz` = 28 requests deep. Writes are drowning this device. Combined with the `vmstat` swap-out above, the story is coherent: memory pressure → swap writes → storage queue explosion → everything blocked. (Order of causation matters — this disk isn't "bad," it's the victim; fix the memory problem.)

**The famous red herring:**
```
Device   r/s      w/s    rkB/s    wkB/s  ... r_await w_await aqu-sz  %util
nvme0n1  38000.0  2100.0 512000.0 84000.0 ...   0.18    0.31   3.10  100.00
```
`%util` = 100%!! And... `r_await` = 0.18ms, perfectly healthy NVMe latency at 38K reads/sec. This drive is *busy*, not *saturated* — `%util` means "had ≥1 request outstanding," which parallel flash devices hit constantly while nowhere near their ceiling (disk guide §3). If someone pages you over `%util` alone, send them `await`.

**Red herring #2 — the burst:** one 10-second window of `w_await` = 90ms during a log rotation or checkpoint flush, back to 2ms afterward. Bursts that clear are normal; **sustained** elevation across many consecutive samples is the signal.

---

### A5. `pidstat` — naming the process (what sar can never do)

```bash
$ pidstat -u 1 3
14:24:01  UID   PID  %usr %system  %CPU  CPU  Command
14:24:02 1001  4142  96.0     3.0  99.0    0  java
14:24:02  999  2210   2.0     1.0   3.0    5  postgres

$ pidstat -r 1 3        # memory per process
14:24:02  UID   PID  minflt/s  majflt/s     VSZ      RSS  %MEM  Command
14:24:02 1001  4142   12400.0     85.0  18563024 14892340  46.0  java
```

**What a real problem looks like:** PID 4142 (java) at 99% CPU **pinned to CPU 0** — this is the same hot core from `mpstat`. And on the memory side: `majflt/s` = 85 (it's faulting pages in from disk — memory pressure is hitting *this specific process*) with RSS at ~14GB of a 31GB box. Now re-run `pidstat -r` a few minutes apart: if RSS is climbing steadily with no plateau, that's a **leak trajectory**, and you have the exact process, growth rate, and thread-level view (`pidstat -t -p 4142 1`) to hand the dev team.

**Red herring:** a process showing 99% CPU **briefly and legitimately** — a scheduled report generator, a compaction, a JIT warmup after deploy. High CPU for a process *whose job is computing* isn't inherently wrong; it's a problem when it correlates with the reported slowness and isn't supposed to be running then. Check "should this even be running at 2pm?" before declaring it rogue.

```bash
$ pidstat -d 1 3        # disk I/O per process
14:24:02  UID   PID   kB_rd/s   kB_wr/s  kB_ccwr/s  iodelay  Command
14:24:02    0  1810      0.0    41200.0        0.0      142  kswapd0
```
**Smoking gun in one line:** the top disk writer is `kswapd0` — the kernel's own swap daemon. The storage load isn't application I/O at all; it's the memory subsystem swapping. (If instead the top writer were, say, a `pg_dump` or a backup agent at 400MB/s during business hours — that's your answer too, and it's a scheduling fix.)

---

### A6. `top` — the D-state check

```
  PID USER   PR NI    VIRT     RES  SHR S  %CPU %MEM  TIME+   COMMAND
 4142 app    20  0  17.7g   14.2g  12m D   2.0 46.0  412:11  java
 4188 app    20  0  1220m    88m   9m  D   0.0  0.3    1:02   log-shipper
 4203 app    20  0  2100m   240m  14m  D   0.1  0.8    3:44   worker-3
```
Multiple processes in state `D` (uninterruptible sleep) = blocked on I/O. Find out on *what*:
```bash
$ ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'
 4142 D    rq_qos_wait       java
 4188 D    rq_qos_wait       log-shipper
 4203 D    nfs_wait_bit_killable  worker-3
```
Two stuck in block-layer queue waits (consistent with the saturated `sda` above) — and one stuck on **NFS**, which is a separate lead you'd otherwise have missed entirely. `wchan` is the cheapest high-value column in this whole runbook.

**Red herring:** a single process flickering into `D` for a moment during normal I/O — every disk write passes through brief D-states. It matters when multiple processes sit in `D` persistently across refreshes.

---

### A7. `ss` — sockets and connections

```bash
$ ss -s
Total: 1892
TCP:   48211 (estab 620, closed 47320, orphaned 12, timewait 47290)
```
**What a real problem looks like:** 47K sockets in `timewait`. If the app is *also* logging `connect: cannot assign requested address`, this is **ephemeral port exhaustion** — the app is opening/closing connections at high churn (typically to one backend, through one NAT'd source IP) instead of pooling. Textbook dev-team handoff: the fix is keep-alive/connection pooling in the app, not anything on the host.

**Red herring:** the same 47K timewait **without** any connection errors from the app. Large timewait counts are mostly harmless on modern kernels (network guide §6) — it only bites when the ephemeral range for a specific src/dst pair runs dry. No app errors = note it, move on.

```bash
$ ss -ti dst 10.0.8.44
ESTAB 0 0 10.0.4.12:52144 10.0.8.44:5432
	 cubic rto:204 rtt:2.1/0.4 retrans:0/1841 cwnd:10 ...
ESTAB 0 0 10.0.4.12:52180 10.0.8.44:5432
	 cubic rto:412 rtt:96.3/40.2 retrans:2/1990 cwnd:4 ...
```
**Reading it:** first connection to the DB: rtt 2.1ms, healthy. Second: rtt 96ms, active retransmissions, congestion window collapsed to 4. Per-connection evidence of network trouble to that DB host — now `mtr` tells you where:

```bash
$ mtr -rwzbc 50 10.0.8.44
HOST                    Loss%  Snt  Last  Avg  Best  Wrst StDev
1. 10.0.4.1              0.0%   50   0.4  0.5   0.3   1.1   0.1
2. 10.0.6.1              0.0%   50   0.9  1.0   0.7   2.2   0.2
3. 10.0.7.9             14.0%   50  38.2 41.6   2.1 190.4  48.7
4. 10.0.8.44            14.0%   50  39.0 42.1   2.3 188.9  47.9
```
Loss begins at hop 3 and **persists to the destination** — real loss at/after that hop, ~14%, with huge latency variance. That's a network-team escalation with the exact hop attached.

**The classic mtr red herring:** loss showing at an intermediate hop but **0% at the final destination**:
```
3. core-rtr-2           40.0%   50   1.2  1.4  ...
4. 10.0.8.44             0.0%   50   2.4  2.5  ...
```
Routers deprioritize replying to probes themselves (ICMP rate-limiting) while forwarding your actual traffic perfectly. Loss that doesn't carry through to the destination is cosmetic. Only destination-affecting loss counts.

---

### A8. App-level: `strace -c` and DNS

```bash
$ strace -c -p 4142   # attach ~10s, Ctrl-C
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 94.12   18.204811        3641      5000       121 futex
  3.20    0.619002          62     10000           read
  1.90    0.367551          73      5000           write
```
**What this real problem looks like:** 94% of traced time in `futex` = the process is fighting **its own locks**. Host metrics can be pristine while this happens — it's pure application-internal contention. This finding, plus a thread dump, is the single most useful thing you can hand a dev team for a "slow but host looks fine" case.

**Red herring:** `futex` calls being merely *numerous* in an idle-ish thread pool — worker threads parked on a futex waiting for work is normal. The signal is the **time share** (94% of wall time) combined with actual request slowness, not call count. Also note `strace` itself adds overhead — sample briefly, don't leave it attached.

**DNS — the invisible classic:**
```bash
$ time getent hosts payments-api.internal
10.0.9.31  payments-api.internal
real    0m5.024s
```
**5.024 seconds** — and that suspiciously precise ~5s is the tell: the first nameserver in `/etc/resolv.conf` is dead, and every fresh lookup burns a full 5s timeout before failing over to the second. Produces "app is randomly slow, host is completely clean" and costs 10 seconds to check. (Healthy output: `real 0m0.012s`.) A dev-team symptom report of "slowness comes in ~5s quanta" is this until proven otherwise.

---

## Path B: Slow EARLIER (sar + journalctl)

```bash
$ sar -q -f /var/log/sa/sa01 -s 02:00:00 -e 03:00:00
02:10:01  runq-sz plist-sz  ldavg-1  ldavg-5  ldavg-15  blocked
02:20:01        2      512     6.20     3.10      1.40         9
02:30:01        3      514    14.80    9.60      4.90        16
02:40:01        2      516    15.10   12.20      7.80        18
02:50:01        1      511     4.10    8.90      7.40         2
```
**Reading the story:** load ramps 02:20→02:40 but `runq-sz` never exceeds 3 (on 8 cores) — the load is entirely the `blocked` column. Not CPU. Something I/O-ish ran 02:20–02:50. Pull `sar -d -p` and `-W` for the same window:

```bash
$ sar -d -p -f /var/log/sa/sa01 -s 02:00:00 -e 03:00:00
02:30:01  DEV  tps      rkB/s     wkB/s   aqu-sz   await  %util
02:30:01  sda  512.0    80.0    91200.0    31.2    204.6  99.8
$ sar -W -f /var/log/sa/sa01 -s 02:00:00 -e 03:00:00
02:30:01  pswpin/s pswpout/s
02:30:01      0.00      0.00
```
Heavy *writes* with 200ms await, **no swap** → not memory. Something wrote ~90MB/s for half an hour at 2am. Now the log check:
```bash
$ grep CRON /var/log/syslog | grep "^Jul  1 02:2"
Jul  1 02:20:01 host CRON[9912]: (root) CMD (/usr/local/bin/backup-full.sh)
```
Case closed: the nightly full backup saturated the shared data volume, blocking the app's writes. Fix is scheduling/throttling/moving the backup — nothing is "broken."

**Red herring in historical mode:** finding *a* anomaly in the window that doesn't match the symptom's shape. If devs report slowness 02:20–02:50 and you find a network retransmit blip at 02:05 that cleared by 02:10, that's not your cause — timeline alignment is the whole game in historical analysis. The cause's ramp should start at or just before the symptom's start, and clear when it clears.

**Recurring-pattern check:** same window across multiple days —
```bash
for f in /var/log/sa/sa2[5-9] /var/log/sa/sa30 /var/log/sa/sa01; do echo "== $f"; sar -q -f $f -s 02:00:00 -e 03:00:00 | tail -4; done
```
Same spike every night at 02:20 = scheduled job, definitively — not an incident, a calendar entry.

---

## Step 2: Corroborate (unchanged rule: two independent signals before you call it)

| Suspected cause | Primary evidence | Second signal |
|---|---|---|
| Memory leak | `pidstat -r` RSS climbing | `journalctl -k` OOM entries; app heap metrics |
| Disk bottleneck | `iostat` await >> baseline | `iotop`/`pidstat -d` naming the writer; cloud volume throttle graphs |
| CPU / hot thread | `mpstat` one hot core | `pidstat -t` naming the thread |
| Lock contention | `strace -c` futex-dominated | thread dump showing waiters on one monitor/mutex |
| Network loss | `ss -ti` retrans per connection | `mtr` destination-affecting loss at a hop |
| Noisy neighbor | `%steal` sustained | provider host metrics; reproduce on another instance |
| DNS | `getent` ~5s | app latency histogram clustering at 5s multiples |

---

## Step 3: The Dev-Team Handoff — What to Send and Why It Helps Them

This is the part that turns your infra findings into something devs can act on. The principle: **hand them the process/thread/query/endpoint level, with timestamps, not just "the host was busy."** Each row includes what they can do with it on their side.

| Your finding | What to send them | What they do with it |
|---|---|---|
| Hot single thread (mpstat + `pidstat -t -p PID 1`) | PID **and TID** of the hot thread, its %CPU, timestamps | Map TID to a thread name (e.g. `jstack`/`py-spy` — Java TIDs match jstack's `nid=` in hex), find the code that thread runs, profile that path |
| Futex-dominated strace | The strace -c summary + a thread dump you trigger (`kill -3` for JVM, `py-spy dump`, etc.) taken *during* slowness | Identify the contended lock/monitor from the dump — waiters all piled on one object is the fix location |
| Memory leak trajectory | PID, RSS-over-time numbers (two `pidstat -r` samples ≥15 min apart), OOM-kill log line if any | Take heap dumps/enable allocation profiling on that process; growth *rate* tells them how urgent and helps spot the leaking allocation site between two dumps |
| Ephemeral port exhaustion (`ss -s` + app connect errors) | timewait count, the dst host:port pair being churned (`ss -tan | awk '{print $5}' | sort | uniq -c | sort -rn | head`), sample app error line | Add/verify connection pooling & keep-alive for that specific client; that dst pair tells them *which* client library to look at |
| Per-connection retrans to DB (`ss -ti`) | The dst host, rtt/retrans numbers, mtr output with the lossy hop | Add client-side timeouts/retries appropriate to the real network conditions; they also now know DB slowness isn't their query plans — skips a whole false lead |
| Backup/batch collision (Path B case) | The exact window, the cron entry, the device it saturated | Confirm which app operations are latency-sensitive in that window; maybe their own batch jobs can move too — scheduling is often app-owned |
| DNS 5s stalls | The `time getent` output, the resolver IPs from `/etc/resolv.conf` | Grep their latency histograms for ~5s modes to confirm blast radius; add caching/lower timeouts in their HTTP clients while infra fixes the resolver |
| Tiny unbuffered I/O (`strace` showing millions of 1–16 byte reads/writes) | Syscall counts + avg size from strace -c, the fd/file involved (`ls -l /proc/PID/fd`) | Buffer the I/O in code — a one-line stream-wrapper fix that no infra change can substitute for |
| **Host completely clean** | Say so explicitly, with the ruled-out list (CPU/mem/disk/net/steal all normal in window X–Y) | This is *hugely* useful to them: they stop suspecting infra and go straight to APM traces, DB slow-query log (`pg_stat_statements` / slow log for window X–Y), dependency latency, and code-level profiling |

**Universal handoff hygiene — every report should carry:**
1. **Exact window** (start–end, timezone) — lets them line up *their* logs/APM/deploy history against yours.
2. **Numbers, not adjectives** — "w_await 187ms vs 3ms baseline, 02:20–02:50" beats "disk was slow." Baselines included, or the number means nothing to them.
3. **PID/TID/dst-host specificity** wherever you have it — resource-level findings make devs guess; process-level findings let them act.
4. **Onset shape** — sudden cliff (points at a deploy/config/event: "check what shipped at 14:10") vs. gradual ramp (points at a leak or data growth: "check what accumulates").
5. **One-off vs. recurring** — recurring-at-the-same-time reframes the whole investigation from "incident" to "calendar."
6. **What you've ruled out** — negative results prevent them from re-investigating dead ends; half the value of good triage is the pruning.
7. **Ask for their timeline back** — deploy times, feature-flag flips, traffic anomalies. Correlation runs both directions; their 14:09 deploy next to your 14:10 cliff finishes the diagnosis.

---

## One-Page Cheat Sheet

```
FIRST QUESTION: slow NOW, or slow EARLIER?

── NOW ─────────────────────────────────────────────────────
uptime                → 1m>15m = building; load alone proves NOTHING yet
dmesg -T | tail -30   → OOM/disk errors = free root cause. CHECK TIMESTAMPS (stale = red herring)
vmstat 1 5            → skip line 1. si/so>0 = MEMORY. r>cores+us high = CPU (maybe fine!).
                        b high+wa high = I/O. swpd static w/ si/so=0 = red herring.
mpstat -P ALL 1 3     → one core hot = single-thread. %soft on one core = IRQ pinning.
                        st sustained = noisy neighbor. Even+high = healthy parallel load.
iostat -xz 1 3        → await vs BASELINE is the signal. %util=100 on NVMe w/ low await = fine.
pidstat -u/-r/-d 1    → NAME the process. kswapd0 top writer = memory, not disk.
top / ps+wchan        → multiple persistent D-state = blocked; wchan says on WHAT (nfs? blk queue?)
ss -s / ss -ti        → timewait piles matter ONLY with app connect errors. per-conn rtt/retrans → DB path.
mtr -rwzbc 50 <dst>   → loss must persist TO DESTINATION; mid-hop-only loss = ICMP dedprio, ignore.
strace -c -p PID      → futex-dominated TIME = lock contention (host can be clean!). Sample briefly.
time getent hosts X   → ~5.0s = dead resolver. The classic clean-host mystery.

── EARLIER ─────────────────────────────────────────────────
sar -q → split load into runq-sz vs blocked FIRST.
sar -u ALL/-r/-W/-B/-d -p/-n ETCP,EDEV for same window, priority: swap→await→steal→runq→retrans
journalctl -k / grep CRON for the window → names the event.
Timeline alignment is everything: cause ramp must match symptom shape. Wrong-time anomaly = red herring.
Same window, multiple days = cron/backup, not an incident.

── HANDOFF ─────────────────────────────────────────────────
Window + numbers-with-baselines + PID/TID/dst + onset shape + recurring? + ruled-out list.
Clean host is a FINDING — say it, so devs go straight to APM/DB/deps.
Ask for their deploy/flag timeline back.
```
