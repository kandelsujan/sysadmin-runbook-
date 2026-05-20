# Linux CPU Troubleshooting Guide for Sysadmins

A practical, command-by-command walkthrough for diagnosing CPU issues on Linux systems. Each section explains what to run, what the output means, and what to do about it.

---

## 1. Understanding the Problem Before You Type

Before reaching for tools, define what "CPU issue" actually means in your case. The fix path is very different for each:

- **High CPU utilization** — processes are consuming cycles. Could be normal (workload), abusive (runaway process), or malicious (cryptominer).
- **High load average, but low CPU usage** — processes are stuck waiting (usually on I/O or locks), not actually crunching numbers.
- **CPU throttling / low performance** — the hardware is healthy but the kernel governor, thermal limits, or BIOS settings are capping it.
- **Soft lockups, hard lockups, stalls** — kernel-level problems, often hardware or driver related.
- **Steal time** — you're on a VM and the hypervisor is starving you.

Knowing which bucket you're in saves an hour of poking the wrong tools.

---

## 2. The First 60 Seconds: Quick Triage

When you SSH into a misbehaving box, run these in order. Brendan Gregg's "60-second checklist" is the canonical starting point.

```bash
uptime
dmesg | tail -50
vmstat 1 5
mpstat -P ALL 1 3
pidstat 1 3
iostat -xz 1 3
free -m
sar -n DEV 1 3
sar -n TCP,ETCP 1 3
top
```

You're not deeply analyzing each one — you're scanning for anomalies. Below, I'll go through the CPU-relevant ones in depth.

---

## 3. Know Your Denominator — How Many CPUs Do You Actually Have?

**This is the step everyone skips and then misreads every number that follows.** A load average of 8 means one thing on a 2-core VM and something completely different on a 64-core server. Before you interpret a single utilization figure, find out what 100% looks like on this box.

### Quick count

```bash
$ nproc
8
```

`nproc` returns the number of logical CPUs available to the current process. This is what the scheduler sees and what every utilization tool is measured against. **This is the number you compare load average to.**

But "8 logical CPUs" can mean several different physical realities, and the difference matters when you're diagnosing performance. Get the full picture:

### Full topology with `lscpu`

```bash
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Byte Order:            Little Endian
CPU(s):                  8
  On-line CPU(s) list:   0-7
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
    CPU family:          6
    Model:               85
    Thread(s) per core:  2
    Core(s) per socket:  4
    Socket(s):           1
    Stepping:            7
    CPU max MHz:         4000.0000
    CPU min MHz:         800.0000
NUMA:
  NUMA node(s):          1
  NUMA node0 CPU(s):     0-7
Vulnerabilities:
  Mds:                   Not affected
  Spectre v1:            Mitigation; usercopy/swapgs barriers and __user pointer sanitization
```

**Read this carefully — it tells you what your "8 CPUs" really are:**

- `CPU(s): 8` — 8 logical CPUs (what `nproc` reports, what the scheduler uses).
- `Thread(s) per core: 2` — hyperthreading is on. So you have 4 physical cores presenting as 8 logical CPUs.
- `Core(s) per socket: 4` — 4 physical cores per socket.
- `Socket(s): 1` — one physical CPU package.
- `NUMA node(s): 1` — single NUMA domain; no cross-socket memory latency concerns.

**Why this matters for diagnosis:**

- **Hyperthreaded "cores" aren't real cores.** Two hyperthreads share execution units. On heavily integer-bound or pipeline-saturating workloads, the second thread might give you only 15–30% extra throughput, not 100%. So 100% utilization across all 8 logical CPUs is *not* the same as 100% utilization across 8 physical cores. If your app is bottlenecked and `htop` shows all 8 CPUs maxed, you might still benefit from optimizing — you're not as saturated as it looks.
- **NUMA matters at 2+ sockets.** If `lscpu` shows `NUMA node(s): 2` or more, processes can suffer big latency penalties when accessing memory attached to the *other* socket. You'll want `numactl --hardware` and per-node stats from `numastat`.
- **Cloud "vCPUs" are usually hyperthreads.** An AWS instance with 8 vCPUs is almost always 4 physical cores with HT. Plan capacity accordingly.

### Quick alternatives

```bash
# Just the logical CPU count
$ getconf _NPROCESSORS_ONLN
8

# Physical vs logical breakdown
$ grep -E '^(processor|physical id|core id)' /proc/cpuinfo | head
processor       : 0
physical id     : 0
core id         : 0
processor       : 1
physical id     : 0
core id         : 0      # <-- same core as processor 0 (HT sibling)
processor       : 2
physical id     : 0
core id         : 1
processor       : 3
physical id     : 0
core id         : 1      # <-- same core as processor 2 (HT sibling)
```

When `processor` 0 and 1 share the same `physical id` and `core id`, they are hyperthread siblings on the same physical core.

### Check cgroup limits (containers, systemd units)

Even if the host has 64 CPUs, your process may be capped:

```bash
# Inside a container or a systemd unit with CPUQuota
$ cat /sys/fs/cgroup/cpu.max
200000 100000
```

That reads as: 200,000 microseconds of CPU per 100,000-microsecond period = **2 CPUs of quota**. So even though `nproc` may report 64, this cgroup can only use 2 worth. A workload appearing "throttled" with no apparent reason is often this. Confirm with:

```bash
$ cat /sys/fs/cgroup/cpu.stat
nr_periods 18421
nr_throttled 8124
throttled_usec 142800312
```

A growing `nr_throttled` and `throttled_usec` means the cgroup is hitting its CPU limit and being suspended. The application sees this as latency spikes; from outside the container it looks fine.

**Bottom line:** before you touch `top` or `uptime`, you should know three numbers: logical CPUs, physical cores, and any cgroup quota in effect. The rest of this guide assumes you have them.

---

## 4. `uptime` — Load Average (Now With Context)

```bash
$ uptime
 14:32:01 up 47 days,  3:18,  2 users,  load average: 8.42, 4.19, 2.05
```

**Interpretation:**

- Three numbers = 1-minute, 5-minute, 15-minute load averages.
- Load average on Linux counts processes that are runnable **or** in uninterruptible sleep (D state — usually waiting on disk or NFS). This is a Linux-specific quirk that other Unixes don't share; it means high load on Linux doesn't necessarily mean CPU pressure.
- **Now apply your denominator from section 3.** Load of 8.42 on the example 8-CPU box from `lscpu` above means the run queue is roughly saturating all logical CPUs — fully loaded but not overloaded. The same load on a 2-CPU VM would mean ~4× oversubscription, and you'd expect visible latency. On a 64-CPU server, 8.42 is ~13% utilization and probably nothing to worry about.
- A useful rule of thumb: **load average ÷ logical CPU count = normalized load.** Sustained values above 1.0 indicate the system can't keep up with demand; values around 0.7 are a reasonable "investigate now" threshold for production servers.
- The trend matters as much as the value: `8.42, 4.19, 2.05` means load is rising sharply (1-min > 5-min > 15-min). `2.05, 4.19, 8.42` means it's recovering. A flat `8.42, 8.40, 8.39` means steady-state — whatever it is, it's been going on for a while.

**What to do next:** if normalized load is high and rising, you need to figure out whether it's CPU-bound or I/O-bound. That's `vmstat`'s job — and specifically, whether the queue is full of `r` (runnable, real CPU pressure) or `b` (blocked, waiting on something else).

---

## 5. `vmstat` — Run Queue vs. Blocked Processes

```bash
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 6  0      0 142336 198432 5421120    0    0    12    42 1124 2210 78  9  12  1  0
 7  0      0 141204 198432 5421120    0    0     0    16 2104 4520 82  8  10  0  0
 8  1      0 140112 198432 5421120    0    0     0    32 2310 4880 85 10   5  0  0
 9  0      0 138992 198432 5421120    0    0     0     8 2420 5012 88  9   3  0  0
```

**The key columns for CPU work:**

- `r` — processes runnable or running. If `r` consistently exceeds your CPU count, you're CPU-saturated. Above, `r=6,7,8,9` on (let's say) a 4-CPU box means there's a queue.
- `b` — processes blocked on I/O (D state). High `b` with low CPU usage = I/O bound, not CPU bound. Don't chase the wrong problem.
- `us` — user-space CPU %. Application code.
- `sy` — kernel/system CPU %. Syscalls, context switches, network stack.
- `id` — idle %.
- `wa` — I/O wait %. CPU is idle but waiting for disk.
- `st` — steal %. **Critical for VMs** — % of time the hypervisor stole from you to give to another guest. Anything sustained above ~5% on a VM is a problem you can't fix from inside the guest.
- `cs` — context switches/sec. Very high values (tens of thousands) can indicate thrashing, lock contention, or a process with too many threads.

**Diagnosis from the example above:** `r` is growing, `us` is high (~85%), `sy` is moderate, `wa` and `st` are near zero. This is a clean CPU-bound workload — a user-space process is hammering the cores. Now go find it.

---

## 6. `mpstat` — Per-CPU Breakdown

```bash
$ mpstat -P ALL 1 3
Linux 5.15.0-89-generic (web-prod-03)    11/14/2025      _x86_64_        (8 CPU)

02:35:14 PM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
02:35:15 PM  all   42.13    0.00    6.25    0.12    0.00    0.50    0.00    0.00    0.00   51.00
02:35:15 PM    0   98.02    0.00    1.98    0.00    0.00    0.00    0.00    0.00    0.00    0.00
02:35:15 PM    1   12.00    0.00    8.00    0.00    0.00    0.00    0.00    0.00    0.00   80.00
02:35:15 PM    2   15.84    0.00    7.92    0.00    0.00    0.99    0.00    0.00    0.00   75.25
02:35:15 PM    3   13.13    0.00    6.06    0.00    0.00    0.00    0.00    0.00    0.00   80.81
02:35:15 PM    4   14.00    0.00    8.00    1.00    0.00    1.00    0.00    0.00    0.00   76.00
02:35:15 PM    5   12.12    0.00    7.07    0.00    0.00    1.01    0.00    0.00    0.00   79.80
02:35:15 PM    6   11.11    0.00    6.06    0.00    0.00    0.00    0.00    0.00    0.00   82.83
02:35:15 PM    7   13.00    0.00    5.00    0.00    0.00    1.00    0.00    0.00    0.00   81.00
```

**Interpretation:**

- The `all` row averages everything. But the per-CPU rows tell the real story.
- **CPU 0 is pinned at 98% user, while all other CPUs are mostly idle.** This is a classic single-threaded bottleneck — the workload isn't parallelized, or a process is pinned to one core. Adding cores will not help; you need to either parallelize the workload or find why it's pinned.
- If `%soft` (softirq) is high on one core, it's usually network interrupt handling — look into RPS/RSS to spread it across cores.
- If `%irq` is high, hardware interrupts are saturating a core — same fix path with `irqbalance` or manual `/proc/irq/*/smp_affinity` tuning.

**Use this command to detect:** load imbalance, IRQ saturation, NUMA issues, and single-threaded apps masquerading as system-wide problems.

---

## 7. `top` and `htop` — Finding the Process

```bash
$ top -o %CPU
top - 14:38:22 up 47 days,  3:24,  2 users,  load average: 8.91, 6.42, 3.18
Tasks: 312 total,   3 running, 309 sleeping,   0 stopped,   0 zombie
%Cpu(s): 78.4 us,  9.2 sy,  0.0 ni, 11.4 id,  0.8 wa,  0.0 hi,  0.2 si,  0.0 st
MiB Mem :  15998.5 total,   1421.3 free,   8210.4 used,   6366.8 buff/cache

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
  18472 mysql     20   0 4821336 2.1g   18432 S 312.5  13.4   1241:18 mysqld
  19284 www-data  20   0  398124  82144  14220 R  45.2   0.5    12:33 php-fpm
   2104 root      20   0   12480   6244   4128 S   3.1   0.0   142:18 systemd
```

**Things to look at:**

- `%CPU` over 100% — `top` shows per-process CPU as a percentage where one full core = 100%. So `mysqld` at 312.5% means it's using ~3.1 cores worth.
- `S` column (state): `R` = running, `S` = sleeping (waiting for an event), `D` = uninterruptible sleep (usually disk I/O — these processes can't be killed with SIGTERM/SIGKILL until they return from the syscall), `Z` = zombie, `T` = stopped.
- Sort by CPU with `P` in interactive mode, by memory with `M`.

**Tip:** press `1` in top to see per-CPU breakdown inline. Press `H` to see threads instead of processes — useful when one process has many threads and you want to find the hot one.

`htop` is the friendlier version: arrow keys to scroll, F5 for tree view (shows parent/child), F6 to sort. Tree view is gold for figuring out which service spawned a runaway worker.

---

## 8. `pidstat` — Per-Process History

`top` is a snapshot. `pidstat` gives you trend data per process:

```bash
$ pidstat 1 5
Linux 5.15.0-89-generic   11/14/2025   _x86_64_   (8 CPU)

02:42:01 PM   UID       PID    %usr %system  %guest    %CPU   CPU  Command
02:42:02 PM   999     18472   285.0    27.0    0.0    312.0     3  mysqld
02:42:02 PM    33     19284    38.0     7.0    0.0     45.0     1  php-fpm
02:42:02 PM     0      2104     2.0     1.0    0.0      3.0     0  systemd
```

**Useful flags:**

- `pidstat -t 1` — show threads
- `pidstat -d 1` — disk I/O per process
- `pidstat -w 1` — context switches per process (find lock-contention culprits)
- `pidstat -r 1` — memory faults per process

`pidstat -t` is particularly valuable: when `top` shows a process at 800% CPU on a 16-core box, `-t` will show you whether it's 8 threads at 100% each (parallel scaling well) or one thread at 100% with 7 mostly idle (poorly threaded).

---

## 9. Identifying What a Process Is Actually Doing

You know the PID. Now you need to know **why** it's burning CPU.

### `ps` for context

```bash
$ ps -p 18472 -o pid,ppid,user,etime,cmd
    PID    PPID USER     ELAPSED CMD
  18472       1 mysql   12-04:18:22 /usr/sbin/mysqld --daemonize --pid-file=/run/mysqld/mysqld.pid
```

`etime` (elapsed time) tells you how long it's been running. A process burning CPU for 12 days at high rate is different from one that started 5 minutes ago.

### `strace` — see syscalls in real time

```bash
$ sudo strace -c -p 18472
strace: Process 18472 attached
^Cstrace: Process 18472 detached
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 42.18    0.821443          12     68453           futex
 31.22    0.608112           4    152031           read
 18.04    0.351442          11     31876           write
  5.18    0.100884          18      5604           epoll_wait
  3.38    0.065831           7      9412           recvfrom
------ ----------- ----------- --------- --------- ----------------
100.00    1.947712                267376           total
```

**Interpretation:** Almost half this process's time is in `futex` (userspace mutex). That's lock contention — threads waiting on each other. The fix is at the application level (reducing lock scope, lock-free data structures, etc.), not the OS.

**Warning:** `strace` has significant overhead (it stops the process at every syscall). Don't leave it running on a production process for long. Use `-c` (summary) over running it interactively, and detach quickly.

### `perf top` — sampling profiler, much lower overhead

```bash
$ sudo perf top -p 18472
Samples: 42K of event 'cpu-clock', 4000 Hz, Event count (approx.): 8742110334
Overhead  Shared Object       Symbol
  18.42%  mysqld              [.] my_strnncoll_utf8mb4
  12.18%  mysqld              [.] row_search_mvcc
   8.42%  [kernel]            [k] _raw_spin_lock_irqsave
   6.18%  mysqld              [.] ha_innobase::index_read
   4.92%  libc-2.31.so        [.] __memcpy_avx_unaligned_erms
```

This is far more informative than `strace`. You see exactly which functions are eating cycles. For MySQL above, `my_strnncoll_utf8mb4` is the UTF-8 collation comparison — usually a sign of inefficient queries doing string comparisons that can't use indexes.

`perf` requires `linux-tools-common` (or your distro's equivalent) and root.

### Flame graphs

For deeper analysis, generate a flame graph:

```bash
sudo perf record -F 99 -p 18472 -g -- sleep 30
sudo perf script > out.perf
# Use Brendan Gregg's flamegraph.pl
./stackcollapse-perf.pl out.perf | ./flamegraph.pl > flame.svg
```

The resulting SVG shows where time is spent up and down the call stack. This is the gold standard for CPU profiling on Linux.

---

## 10. CPU Frequency and Throttling

A process can be "using 100% CPU" while the CPU is actually running at 800 MHz instead of 3.6 GHz, because the governor decided to save power or thermal limits kicked in.

### Check current frequencies

```bash
$ cat /proc/cpuinfo | grep "MHz"
cpu MHz         : 800.014
cpu MHz         : 800.214
cpu MHz         : 3601.842
cpu MHz         : 800.119
```

Or more cleanly:

```bash
$ grep -E '^model name|^cpu MHz' /proc/cpuinfo | paste - -
model name      : Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz   cpu MHz         : 800.014
```

### Check governor and scaling

```bash
$ cpupower frequency-info
analyzing CPU 0:
  driver: intel_pstate
  CPUs which run at the same hardware frequency: 0
  CPUs which need to have their frequency coordinated by software: 0
  maximum transition latency:  Cannot determine or is not supported.
  hardware limits: 800 MHz - 4.00 GHz
  available cpufreq governors: performance powersave
  current policy: frequency should be within 800 MHz and 4.00 GHz.
                  The governor "powersave" may decide which speed to use
                  within this range.
  current CPU frequency: 1.20 GHz (asserted by call to hardware)
  boost state support:
    Supported: yes
    Active: yes
```

**Interpretation:** The governor is `powersave`. On a busy server, this can leave performance on the table. Switch to `performance`:

```bash
$ sudo cpupower frequency-set -g performance
```

For permanent change, set it via systemd unit or your distro's CPU frequency config.

### Thermal throttling

```bash
$ dmesg | grep -i "thermal\|throttl"
[12384.234] CPU2: Package temperature above threshold, cpu clock throttled (total events = 142)
[12384.235] CPU3: Core temperature above threshold, cpu clock throttled (total events = 89)
```

That's the kernel telling you the CPU got too hot and reduced its clock speed to cool down. Causes: dust in the heatsink, failed fan, dried thermal paste, undersized cooling for the workload, or a runaway compute job. Check actual temperatures:

```bash
$ sensors
coretemp-isa-0000
Adapter: ISA adapter
Package id 0:  +88.0°C  (high = +84.0°C, crit = +100.0°C)
Core 0:        +85.0°C
Core 1:        +89.0°C
Core 2:        +86.0°C
Core 3:        +87.0°C
```

Anything sustained above the `high` threshold means throttling will occur. Above `crit` and the system will emergency-shut-down to protect itself.

### Check throttling counters

```bash
$ grep . /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count
/sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count:0
/sys/devices/system/cpu/cpu1/thermal_throttle/core_throttle_count:142
/sys/devices/system/cpu/cpu2/thermal_throttle/core_throttle_count:89
```

These counters are monotonic since boot. A non-zero, growing value = active thermal problem.

---

## 11. Steal Time on Virtual Machines

If you're inside a VM (cloud instance, KVM guest, etc.), `%steal` from `vmstat` or `mpstat` is critical:

```bash
$ mpstat 1 5
02:55:11 PM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
02:55:12 PM  all   30.12    0.00    4.18    0.00    0.00    0.12   42.18    0.00    0.00   23.40
```

**42% steal time** means almost half the wall-clock time, the hypervisor scheduled other guests instead of yours. Symptoms inside the guest: high load average with no apparent reason, sluggish responses, slow benchmark times. You cannot fix this from inside the VM. Solutions:

- Migrate to a less-noisy host (request live migration from your cloud provider, or stop/start the instance to move it).
- Upgrade to a dedicated/isolated instance type.
- Reduce noisy-neighbor contention by avoiding burstable tiers (e.g., AWS `t` family) for sustained workloads.

---

## 12. Soft Lockups and Hung Tasks

When the kernel itself complains:

```bash
$ dmesg | grep -i "soft lockup\|hung_task\|rcu_sched"
[18234.18] watchdog: BUG: soft lockup - CPU#3 stuck for 22s! [kworker/3:1:18742]
[18234.19] Modules linked in: nf_conntrack_netlink xt_NFLOG ...
[18234.20] CPU: 3 PID: 18742 Comm: kworker/3:1 Tainted: P OE 5.15.0-89-generic
```

**What it means:** a task held a CPU for >20 seconds without yielding. Common causes:

- Buggy driver in a tight loop.
- Failing hardware (especially memory or storage).
- Heavily contended kernel lock.
- Live-lock in a kernel subsystem.

The stack trace right after the message tells you which kernel function was stuck. If it's in a vendor driver (network card, RAID controller, GPU), update the driver/firmware.

`hung_task` messages indicate a task in D state for >120 seconds — usually I/O that never completed (failing disk, stuck NFS mount).

---

## 13. Context Switches and Interrupts

```bash
$ vmstat 1 3
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free  ...   in     cs us sy id wa st
 4  0      0 ...        148231 312420 22 65 12  1  0
```

`cs` of 312,420 per second is **very** high on most workloads. Combined with `sy` of 65%, the system is spending the majority of time switching between processes rather than doing work. Causes:

- Far too many threads contending for the same locks.
- Thrashing across NUMA nodes.
- Excessive use of polling/epoll with short timeouts.

Use `pidstat -w 1` to find which process is doing all the switching, then profile with `perf` to find why.

For interrupts:

```bash
$ cat /proc/interrupts | head
           CPU0       CPU1       CPU2       CPU3
  0:         42          0          0          0   IO-APIC   2-edge      timer
  1:          9          0          0          0   IO-APIC   1-edge      i8042
  8:          0          0          0          0   IO-APIC   8-edge      rtc0
 24:    8123421     112340     112301     112400   IR-PCI-MSI 524288-edge eth0-rx-0
```

If `eth0-rx-0` is firing 8M times only on CPU0, you have IRQ affinity stuck to one core. Spread it:

```bash
$ sudo systemctl enable --now irqbalance
```

Or manually pin via `/proc/irq/24/smp_affinity`.

---

## 14. The Cryptominer Check

If a customer-facing box suddenly has 100% CPU, eliminate the obvious malware case:

```bash
# Look for unfamiliar high-CPU processes
$ ps auxf | sort -rk 3 | head -20

# Check executable paths — legitimate binaries shouldn't be in /tmp, /dev/shm, /var/tmp
$ ls -la /proc/<PID>/exe

# Check for processes with deleted binaries (common malware tactic)
$ ls -la /proc/*/exe 2>/dev/null | grep deleted

# Check outbound connections (mining pools)
$ ss -tnp | grep ESTAB
```

Common red flags: process binary in `/tmp`, process name disguised as `[kworker/0:0]` (kernel threads should not appear in `ps aux` with high CPU and a deleted binary), outbound connections to known pool ports (3333, 4444, 5555, 7777, 14444, 14433).

---

## 15. Putting It All Together — A Diagnostic Flow

Here's a flow I run mentally on a CPU complaint:

1. **`nproc` / `lscpu`** — How many logical CPUs, physical cores, sockets, NUMA nodes? Any cgroup quota? Without this, no other number means anything.
2. **`uptime`** — Load high relative to CPU count? Rising or falling?
3. **`vmstat 1 5`** — Is it `r` (runnable, real CPU pressure) or `b` (blocked, I/O wait)? Any `st` (steal, hypervisor issue)?
4. **`mpstat -P ALL 1 3`** — Is load balanced across cores, or pinned to one?
5. **`top` / `pidstat`** — Which process? Single-threaded or multi-threaded?
6. **`ps -p <pid> -o ...`** — How long has it been running? Is it a known service?
7. **`perf top -p <pid>`** — What functions are hot?
8. **`dmesg | tail`** — Any kernel messages (thermal, soft lockup, OOM)?
9. **`sensors` / throttle counters** — Hardware healthy?
10. **`cpupower frequency-info`** — Governor in the right mode?

Most CPU incidents resolve at step 5 or 6. The deeper steps are for the genuinely weird ones: regressions after a kernel upgrade, hardware degradation, NUMA pathologies, and the like.

---

## 16. Useful One-Liners to Keep Handy

```bash
# Top 10 CPU-using processes (snapshot)
ps -eo pid,user,%cpu,%mem,cmd --sort=-%cpu | head -11

# All threads of a process, sorted by CPU
ps -L -p <PID> -o pid,tid,pcpu,comm --sort=-pcpu

# Watch a single core's frequency in real time
watch -n1 "grep MHz /proc/cpuinfo | awk '{print NR-1, \$4}'"

# How many runnable tasks right now
cat /proc/loadavg

# Per-process CPU time (cumulative) since start
ps -eo pid,user,time,cmd --sort=-time | head

# Find processes in D state (uninterruptible sleep — usually I/O stuck)
ps -eo pid,state,cmd | awk '$2=="D"'

# Quick check: are we throttled right now?
for i in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
  echo "$i: $(cat $i)"
done

# CPU info summary
lscpu
```

---

## 17. Tools to Install Once and Forget

These aren't always on by default but are essential when you need them:

- `sysstat` — gives you `mpstat`, `pidstat`, `iostat`, `sar`. Enable `sar` collection (`/etc/default/sysstat`) so you have historical data when something blows up.
- `linux-tools-<kernel-version>` (Debian/Ubuntu) or `perf` (RHEL/Fedora) — `perf` profiler.
- `htop` — interactive process viewer.
- `iotop` — per-process I/O (useful when you suspect I/O wait masquerading as CPU).
- `cpupower` or `cpufrequtils` — governor management.
- `lm-sensors` — temperature monitoring (`sensors-detect` first).
- `bcc-tools` / `bpftrace` — eBPF-based observability. Steeper learning curve, vastly more powerful than `strace`/`perf` for complex problems.

---

## 18. Closing Thoughts

Most CPU issues fall into a small set of patterns:

- One process is doing too much work (find it, profile it, fix the code or scale out).
- Work is poorly distributed across cores (parallelize, pin, or rebalance IRQs).
- The CPU isn't actually running fast (governor, thermal, steal time).
- Something's stuck (soft lockup, D state, lock contention).

The discipline is: don't jump to a tool before you know which bucket you're in. `uptime` → `vmstat` → `mpstat` → `top`/`pidstat` is a four-command path that puts you in the right bucket 90% of the time. The rest of this guide is for the remaining 10%.
