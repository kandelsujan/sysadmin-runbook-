# Diagnosing CPU Issues with `sar`

CPU diagnosis with `sar` trips people up in the opposite direction from memory: instead of a scary-looking-but-fine number, the trap here is a single aggregate percentage (`%idle`, load average) that looks *fine* while masking a real, localized problem — one hot core, one blocked queue, one noisy neighbor stealing cycles. You have to look past the headline number to the breakdown.

This guide covers the CPU-relevant `sar` reports, what real contention looks like, and where people chase red herrings.

---

## 1. Setup

```bash
systemctl status sysstat
sar -u -f /var/log/sa/sa15          # replay historical CPU stats
sar -u 1 10                         # live, 1s interval
sar -u ALL 1 5                      # all CPU sub-metrics, not just the default subset
sar -P ALL 1 5                      # per-CPU breakdown (each core individually)
```

---

## 2. The Core Reports

| Flag | What it shows |
|---|---|
| `sar -u` / `sar -u ALL` | Aggregate CPU utilization breakdown (user/system/iowait/steal/idle) |
| `sar -P ALL` | Same breakdown but **per CPU core** — critical for single-thread bottlenecks |
| `sar -q` | Run queue length, load average |
| `sar -w` | Context switches and process creation rate |

Run together: `sar -u -q 1 5`

---

## 3. `sar -u` — Aggregate CPU Utilization

```
Time    CPU   %user   %nice   %system  %iowait  %steal  %irq   %soft   %guest  %idle
14:20   all   35.20   0.00    8.40     22.10    0.00    0.10   1.20    0.00    33.00
```

| Metric | Meaning |
|---|---|
| `%user` | Time running normal user-space processes |
| `%nice` | User-space time for processes with adjusted (`nice`d) priority |
| `%system` | Time in kernel space (syscalls, scheduling, etc.) |
| `%iowait` | CPU idle *specifically* while waiting on outstanding disk I/O |
| `%steal` | Time this vCPU wanted to run but the **hypervisor** gave the physical core to someone else |
| `%irq` / `%soft` | Hard and soft interrupt handling time |
| `%guest` | Time spent running a guest VM (relevant on hypervisor hosts) |
| `%idle` | Genuinely idle, nothing to do |

### Red herring #1: High `%iowait` mistaken for a CPU problem

`%iowait` counts as "not idle" in some dashboards, so people see low `%idle` and assume the CPU is the bottleneck. It isn't. **`%iowait` means the CPU had literally nothing else to do and was waiting on disk** — the CPU itself is not the constraint; storage is. A box can show `%idle` at 5% purely from `%iowait` at 90%+ while every core is sitting there twiddling its thumbs waiting for disk.

**How to tell the difference:** look at `%user` + `%system` (actual compute work) separately from `%iowait`. If `%iowait` is the dominant number and `%user`/`%system` are low, this is a **storage** ticket wearing a CPU costume — go check `sar -d` (disk), not `sar -P` (per-core compute).

### Smoking gun #1: `%steal` sustained and nonzero

This only applies in virtualized/cloud environments, but it's one of the clearest smoking guns `sar` can hand you. `%steal` means your VM *wanted* CPU time and the hypervisor gave the physical core to a different tenant instead. This is invisible to anything running *inside* the guest other than `sar`/`/proc/stat` — the app just looks "slow" with no obvious cause in application logs.

```
%steal = 25-40% sustained during business hours
```
This is a "noisy neighbor" problem or an under-provisioned/oversold host — not something you can fix by tuning your application. Escalate to your cloud provider or move to a less contended host/instance size.

**Red herring on `%steal`:** brief single-sample spikes of `%steal` (one or two intervals) are common and usually harmless — they happen from routine hypervisor scheduling jitter. Only sustained, repeated `%steal` correlating with actual application slowness is the real signal.

### Smoking gun #2: `%system` disproportionately high relative to `%user`

Healthy compute-bound workloads are usually `%user`-dominant. If `%system` is consistently comparable to or higher than `%user`, the kernel itself is doing unusually heavy lifting — common causes: excessive syscalls (badly-written loops doing tiny reads/writes instead of buffering), heavy network stack processing, page fault storms (cross-check with the memory guide's `sar -B`), or lock contention inside the kernel. This is worth `strace -c` or `perf top` follow-up, not just throwing more cores at it.

---

## 4. `sar -P ALL` — Per-Core Breakdown (where single-thread bottlenecks hide)

```
Time    CPU   %user   %nice   %system  %iowait  %steal  %irq   %soft   %guest  %idle
14:20   all   35.20   0.00    8.40     5.10     0.00    0.10   1.20    0.00    50.00
14:20   0     98.90   0.00    1.10     0.00     0.00    0.00   0.00    0.00    0.00
14:20   1     12.30   0.00    9.80     8.90     0.00    0.20   1.90    0.00    66.90
14:20   2     8.10    0.00    7.20     6.30     0.00    0.10   1.10    0.00    77.20
14:20   3     11.50   0.00    8.90     5.20     0.00    0.30   2.40    0.00    71.70
```

**This is the report that catches what `sar -u` completely hides.** In the example above, `sar -u`'s aggregate `%idle` is a comfortable 50% — looks fine at a glance. But `sar -P ALL` shows CPU 0 pinned at 98.9% `%user` while the other three cores are mostly idle.

**Smoking gun:** one core (or a small subset) pegged near 100% while others sit idle, aggregate `%idle` masking it. This is the signature of:
- A single-threaded application (or a poorly-parallelized hot loop) that can't use more than one core no matter how many are available
- Bad IRQ affinity — all network interrupts pinned to one core (check `/proc/interrupts` and `irqbalance` status)
- A single lock-holding thread serializing work that should be parallel

**Red herring:** don't assume high aggregate `%user` with a flat, even distribution across all cores is a problem by itself — that's just a genuinely CPU-bound, well-parallelized workload using the hardware as intended. The issue is *imbalance*, not raw utilization.

---

## 5. `sar -q` — Run Queue and Load Average

```
Time    runq-sz  plist-sz  ldavg-1  ldavg-5  ldavg-15  blocked
14:20   12       450       8.50     6.20     4.10      3
```

| Metric | Meaning |
|---|---|
| `runq-sz` | Number of processes/threads currently **runnable** and waiting for a CPU |
| `plist-sz` | Total process list size (all processes, not just runnable) |
| `ldavg-1/5/15` | Load average over 1/5/15 minutes |
| `blocked` | Processes blocked waiting on I/O (not CPU — this is a **cross-check** field) |

### Red herring: Load average alone, without context

Load average on Linux counts both processes waiting for CPU *and* processes in uninterruptible sleep (blocked on I/O) — this is a common source of confusion. A `ldavg-1` of 8.5 on a 4-core box looks alarming, but if most of that is coming from the `blocked` column (processes stuck on disk/network I/O) rather than `runq-sz` (processes actually waiting for a free core), it's **not a CPU problem** — it's I/O, and load average is just the messenger.

**How to disambiguate:** compare `runq-sz` to your actual core count.
- `runq-sz` consistently exceeding the number of cores → genuine CPU contention, more runnable work than the hardware can execute at once. **Smoking gun.**
- `runq-sz` low/normal but `blocked` is high and `ldavg` is inflated → the "CPU problem" is actually storage or network I/O backing things up. Go check `sar -d` or the network guide.

### Smoking gun: `runq-sz` sustained above core count, correlated with rising `ldavg-1`

If `runq-sz` is regularly 2-3x your core count and load average is climbing across all three windows (1/5/15 min, meaning it's sustained, not a blip), you have genuine CPU saturation — more work wants to run than you have cores to run it on. Combine with `sar -P ALL` to see whether it's evenly spread (need more cores / horizontal scaling) or concentrated on one core (need to fix parallelism/affinity first, before assuming you need more hardware).

---

## 6. `sar -w` — Context Switches and Process Creation

```
Time    proc/s  cswch/s
14:20   4.20    85400.50
```

| Metric | Meaning |
|---|---|
| `proc/s` | New processes/threads created per second |
| `cswch/s` | Context switches per second |

**Smoking gun:** `cswch/s` unusually high relative to your normal baseline for the same workload — this indicates excessive scheduling overhead: too many threads contending for too few cores, lock contention causing threads to constantly block/wake, or a thread-per-connection architecture creating far more OS threads than the hardware can usefully run in parallel. High context-switch rates burn CPU cycles on overhead (cache/TLB flushes) rather than useful work — this can show up as `%system` being elevated in `sar -u` without a corresponding rise in real throughput.

**Red herring:** `cswch/s` is a workload-relative number — there's no universal "bad" threshold. A busy web server or messaging broker handling thousands of short-lived requests will *legitimately* have a high context-switch rate as part of normal operation. Only treat it as a signal when it's a significant, sustained *deviation from that same system's own historical baseline*, not against some generic number pulled from a blog post.

**`proc/s` spiking** — a sudden burst of new process creation (fork bomb, misbehaving cron job, a script spawning subprocesses in a loop instead of reusing a pool) will show up here clearly and often precedes a load average climb in the following interval — useful for finding root cause vs. symptom when a spike shows up in `sar -q` a few minutes later.

---

## 7. Putting It Together: A Diagnostic Workflow

1. **Establish the time window** for the reported slowness.
2. **Start with `sar -u ALL`** for that window — split out `%iowait` and `%steal` first, since both masquerade as CPU problems but have completely different fixes (storage vs. hypervisor/noisy-neighbor).
3. **If `%user`+`%system` genuinely dominate** (not iowait/steal), move to `sar -P ALL` for the same window — check for imbalance across cores before assuming you need more hardware.
4. **Pull `sar -q`** — compare `runq-sz` to core count, and check whether `blocked` is inflating load average instead of `runq-sz`.
5. **Pull `sar -w`** — compare `cswch/s` against this same system's historical baseline (not a generic threshold) to see if scheduling overhead itself is eating cycles.
6. **Cross-correlate with the memory guide's `sar -B`** (major faults) and the network guide's `sar -n EDEV`/`ETCP` (interrupts, retransmits) for the same window — a lot of "CPU" tickets turn out to be memory pressure or network interrupt load showing up as `%system`/`%soft`.
7. Only after `sar` narrows it to genuine, imbalanced, or overhead-driven compute contention, move to `perf top`, `pidstat -p <pid> 1`, or thread-level profiling to identify the *specific* offending process/thread.

---

## 8. Quick Reference: Red Herring Checklist

Before declaring a CPU problem, ask:

- Is low `%idle` actually **`%iowait`** in disguise — meaning this is a storage problem, not a CPU problem?
- Are you on a **VM/cloud instance** — have you checked `%steal` before blaming your own application?
- Does the aggregate `sar -u` picture look fine while `sar -P ALL` shows one core pegged and the rest idle?
- Is a scary load average actually coming from the **`blocked`** column (I/O-wait processes) rather than `runq-sz` (genuinely CPU-starved processes)?
- Is `cswch/s` actually elevated **relative to this system's own normal baseline**, or just a big-looking number for a naturally chatty workload?
- Does the CPU signal **correlate** with an actual reported symptom in the same time window — or is it an isolated spike with nothing else backing it up?

If you can't separate `%iowait`/`%steal` from real compute time, or you haven't checked per-core distribution, you don't have a CPU diagnosis yet — you have a headline number that could mean three completely different things.
