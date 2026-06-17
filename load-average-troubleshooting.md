# Load Average Troubleshooting Runbook

A practical guide to diagnosing high load average on Linux systems.

---

## 1. What load average actually measures

The three numbers from `uptime`, `top`, or `/proc/loadavg` are the **1-, 5-, and 15-minute** exponentially-weighted averages of the number of processes that are either:

- **Running or runnable** (in state `R` — using or waiting for CPU), **and**
- **Uninterruptible** (in state `D` — usually blocked on I/O such as disk or network filesystem)

This is the single most misunderstood point: on Linux, **load average is not CPU utilization**. A box can show a load of 30 while CPUs sit nearly idle, because the runnable queue is full of processes stuck in `D` state waiting on storage.

### Reading the numbers

Compare load against **CPU core count** (`nproc` or `grep -c ^processor /proc/cpuinfo`):

| Load relative to cores | Interpretation |
|------------------------|----------------|
| Load < cores | Spare capacity; generally healthy |
| Load ≈ cores | Fully utilized, no queue |
| Load > cores | Work is queuing; processes waiting |

Look at the **trend across the three values**, not just the first:

- `1m > 5m > 15m` → load is **rising** (a spike or growing problem)
- `1m < 5m < 15m` → load is **falling** (recovering from an event)
- All three similar → **sustained** condition

> A load of 8.00 means very different things on a 4-core VM (overloaded 2×) versus a 64-core host (almost idle). Always normalize by core count.

---

## 2. First 60 seconds — quick triage

Run these in order. They take seconds and immediately narrow the cause.

```bash
uptime                      # the three load numbers + how long they've been elevated
nproc                       # core count to normalize against
top                         # or htop — sort by CPU (P) and by memory (M)
vmstat 1 5                  # r, b columns; us/sy/wa/id; si/so (swap)
```

Key columns in `vmstat 1`:

- **`r`** — processes runnable/running. If `r` consistently exceeds core count, you are **CPU-bound**.
- **`b`** — processes in uninterruptible sleep. If `b` is high, you are **I/O-bound** (or blocked on something).
- **`wa`** — % CPU time waiting on I/O. High `wa` points at storage.
- **`si`/`so`** — swap in/out. Non-zero means **memory pressure** (see §5).
- **`us`/`sy`** — user vs system (kernel) CPU. High `sy` suggests kernel/syscall overhead.

This split — high `r` vs high `b` — is the fork in the road for everything below.

---

## 3. Branch A: CPU-bound (high `r`, low `wa`)

The runnable queue exceeds available cores and CPUs are busy.

### Identify the offenders

```bash
top -o %CPU                                  # interactive, sort by CPU
ps -eo pid,ppid,user,%cpu,comm --sort=-%cpu | head
pidstat 1 5                                  # per-process CPU over time
mpstat -P ALL 1                              # per-core; spot a single saturated core
```

### Common causes

- A runaway process or infinite loop (one process pinning a core at ~100%).
- Legitimate demand exceeding capacity (traffic spike, batch job, deploy).
- Too many worker threads/processes for the core count (oversized thread pools, fork bombs).
- A single-threaded bottleneck saturating one core while others idle (visible in `mpstat -P ALL`).
- Noisy neighbor on a shared/virtualized host — check **steal time** (`st` in `top`/`vmstat`); high steal means the hypervisor is giving your vCPU to others.

### Remediation

- Identify and (if safe) `renice` or kill the offending process.
- Scale horizontally or vertically if it's genuine demand.
- Tune worker/thread counts to match core count.
- Profile the hot process (`perf top`, language-specific profilers) to fix the code path.

---

## 4. Branch B: I/O-bound (high `b`, high `wa`)

Processes are stuck in `D` state waiting on storage or network filesystems. CPU may look idle.

### Identify the bottleneck

```bash
iostat -xz 1                 # %util, await, aqu-sz per device
iotop -oPa                   # which processes are actually doing I/O
ps -eo pid,state,wchan:30,comm | awk '$2 ~ /D/'   # processes in D state + what they wait on
dmesg -T | tail -50          # disk errors, timeouts, controller resets
```

Key `iostat -x` signals:

- **`%util` near 100%** — device is saturated.
- **High `await`** — average ms per I/O request is climbing (latency problem).
- **High `aqu-sz`** — requests are queuing at the device.

### Common causes

- A slow or failing disk (rising `await`, errors in `dmesg`).
- A process doing heavy or unbatched I/O (large logs, full table scans, backups, `dd`).
- NFS/network storage hangs — `D`-state processes blocked on an unreachable mount.
- Filesystem full or fragmented; journal pressure.
- Swap thrashing presenting as disk I/O (cross-check §5).

### Remediation

- Throttle or reschedule the offending I/O job (`ionice -c3`, run during off-peak).
- For NFS hangs, check the server and network; a stuck mount can wedge many processes.
- Replace failing disks; check RAID/controller health.
- Move hot data to faster storage; add caching; batch writes.

---

## 5. Branch C: Memory pressure / swapping

Memory exhaustion drives load up indirectly — the kernel swaps to disk (adding I/O wait) and the OOM killer may fire.

```bash
free -h                      # available memory, swap usage
vmstat 1 5                   # watch si/so columns
dmesg -T | grep -i -E 'oom|killed process'   # OOM events
cat /proc/pressure/memory    # PSI: memory stall time (kernel 4.20+)
```

Signs: non-zero `si`/`so` in `vmstat`, shrinking `available` in `free`, OOM-killer messages in `dmesg`. Swapping turns a memory problem into an I/O problem, so you may see Branch B symptoms with the real root cause here.

### Remediation

- Find the memory hog: `ps -eo pid,user,%mem,rss,comm --sort=-rss | head`.
- Fix leaks, cap process memory, right-size caches/JVM heaps.
- Add RAM or scale out; tune `vm.swappiness` if swapping is premature.

---

## 6. Less common causes

- **Thundering herd of short-lived processes** — a cron storm or fork loop spikes `r` briefly. Catch with `pidstat 1` or `execsnoop` (bcc/bpftrace).
- **Kernel / driver issues** — high `sy` (system CPU) with no obvious userspace culprit; check `dmesg`, soft lockups, and `perf top`.
- **Lock contention** — many threads runnable but throughput low; look for spinlock/mutex contention with `perf` or application profilers.
- **D-state from anything blocking uninterruptibly** — not only disk: stuck network mounts, kernel bugs, hardware faults. `wchan` tells you where they're blocked.
- **Steal time on cloud/VMs** — neighbors or throttling; `st` column and provider metrics.

---

## 7. Decision flow (summary)

1. **Normalize:** is load actually high relative to `nproc`, and is the trend rising or falling?
2. **Split with `vmstat 1`:**
   - High `r`, low `wa` → **CPU-bound** → §3
   - High `b`, high `wa` → **I/O-bound** → §4
   - Non-zero `si`/`so` → **memory pressure** → §5
3. **Attribute:** find the specific process(es) with `top`, `pidstat`, `iotop`, or D-state inspection.
4. **Confirm root cause** before acting — swapping and failing disks both masquerade as I/O wait.
5. **Remediate**, then watch `uptime`/`vmstat` to confirm the trend reverses.

---

## 8. Command cheat sheet

| Goal | Command |
|------|---------|
| Load + uptime | `uptime` |
| Core count | `nproc` |
| Live overview | `top` / `htop` |
| Runnable vs blocked, swap | `vmstat 1` |
| Per-core CPU | `mpstat -P ALL 1` |
| Per-process CPU | `pidstat 1` |
| Disk latency/util | `iostat -xz 1` |
| Per-process I/O | `iotop -oPa` |
| Processes in D state | `ps -eo pid,state,wchan:30,comm \| awk '$2 ~ /D/'` |
| Memory + swap | `free -h` |
| OOM / disk errors | `dmesg -T \| tail` |
| Pressure stall info | `cat /proc/pressure/{cpu,io,memory}` |

---

## 9. Useful background

- Load average counts **`R` + `D`** processes — it is a queue length, not a utilization percentage.
- Always interpret it **per core**.
- The `1/5/15` trend tells you whether you're heading into or out of trouble.
- `vmstat`'s `r` vs `b` split is the fastest way to decide CPU-bound vs I/O-bound.
- The Pressure Stall Information files (`/proc/pressure/*`) give a clearer "how much are we actually stalled" signal than load average on modern kernels.
