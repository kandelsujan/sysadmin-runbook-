# Linux Memory Troubleshooting Guide for Sysadmins

A practical, field-tested reference for diagnosing memory issues on Linux systems. Each section explains *what* the command does, *why* it matters, shows realistic *sample output*, and walks through *how to interpret* what you're seeing.

---

## Table of Contents

1. [Memory Concepts Every Sysadmin Must Know](#1-memory-concepts-every-sysadmin-must-know)
2. [Quick Triage: First 60 Seconds](#2-quick-triage-first-60-seconds)
3. [Tool: `free`](#3-tool-free)
4. [Tool: `/proc/meminfo`](#4-tool-procmeminfo)
5. [Tool: `vmstat`](#5-tool-vmstat)
6. [Tool: `top` and `htop`](#6-tool-top-and-htop)
7. [Tool: `ps` for Memory Hunting](#7-tool-ps-for-memory-hunting)
8. [Tool: `smem` for Accurate Per-Process Usage](#8-tool-smem-for-accurate-per-process-usage)
9. [Tool: `/proc/<pid>/` Deep Dive](#9-tool-procpid-deep-dive)
10. [Tool: `slabtop` (Kernel Memory)](#10-tool-slabtop-kernel-memory)
11. [Tool: `pmap`](#11-tool-pmap)
12. [Swap Analysis](#12-swap-analysis)
13. [The OOM Killer](#13-the-oom-killer)
14. [Cgroups v2 Memory Limits (Containers)](#14-cgroups-v2-memory-limits-containers)
15. [Memory Leak Investigation Workflow](#15-memory-leak-investigation-workflow)
16. [Tuning Knobs in `/proc/sys/vm/`](#16-tuning-knobs-in-procsysvm)
17. [Common Scenarios and Fixes](#17-common-scenarios-and-fixes)

---

## 1. Memory Concepts Every Sysadmin Must Know

Before touching any tool, internalize these concepts. Most memory "problems" reported by users are actually misunderstandings of these.

**Free memory is wasted memory.** Linux aggressively uses unused RAM for the page cache. A box reporting "100 MB free" out of 64 GB is not in trouble — it's doing its job. The number to watch is **available**, not **free**.

**Virtual vs Resident vs Shared:**
- **VSZ (Virtual Size)** — every byte the process *could* address. Includes memory-mapped files, shared libraries, and reserved-but-unused regions. Often huge and meaningless on its own.
- **RSS (Resident Set Size)** — physical RAM the process is currently holding. Includes shared library pages, so adding RSS across processes double-counts.
- **PSS (Proportional Set Size)** — RSS but shared pages are divided across users. Sum of PSS across all processes ≈ actual RAM used. This is the honest number.
- **USS (Unique Set Size)** — memory that would be freed if the process died right now. Best metric for "how much is *this* process really costing me."

**Page cache vs anonymous memory:**
- **Page cache (file-backed)** — copies of disk content held in RAM. Reclaimable: the kernel can drop it instantly without writing anywhere.
- **Anonymous memory** — heap, stacks, malloc'd memory. Not backed by a file. To reclaim, the kernel must swap it out.

**Cache vs Buffers:** Both are page cache, just accounted differently. Buffers are metadata-ish cache (filesystem structures, raw block device reads). Cache is regular file data. For troubleshooting, treat them as a single bucket: reclaimable file-backed memory.

**Swap is not "extra RAM."** Swap is an overflow safety valve for cold anonymous pages. A system that is actively swapping (high `si`/`so` in vmstat) is in pain. A system with swap *used* but not actively swapping is fine — those are just stale pages parked on disk.

---

## 2. Quick Triage: First 60 Seconds

When someone says "the server is slow, I think it's memory," run these in order:

```bash
free -h                    # Snapshot: is there headroom?
vmstat 1 5                 # Active pressure: are we swapping right now?
dmesg -T | tail -50        # Did the OOM killer fire? Any MCE/ECC errors?
ps aux --sort=-%mem | head # Top 10 memory consumers
```

This four-command sweep answers: *Do we have memory? Are we under pressure? Has the kernel killed anything? Who's the hog?* Everything below is depth on these four questions.

---

## 3. Tool: `free`

The 30-second snapshot. Always use `-h` (human-readable) or `-m` (MiB). Skip `-b` (bytes) unless scripting.

```bash
free -h
```

### Sample Output

```
               total        used        free      shared  buff/cache   available
Mem:            31Gi        18Gi       412Mi       1.2Gi        12Gi        11Gi
Swap:          8.0Gi       1.4Gi       6.6Gi
```

### Interpretation

Read this top to bottom:

- **total: 31Gi** — physical RAM the kernel sees. If this is lower than the hardware spec, check BIOS, `dmidecode -t memory`, or look for `mem=` on the kernel command line.
- **used: 18Gi** — RAM held by processes (anonymous + some other accounting). This is *not* the number to alarm on.
- **free: 412Mi** — completely unused. Looks scary. **It is not scary.**
- **shared: 1.2Gi** — tmpfs and shared memory segments (`/dev/shm`, `shm_open`, etc.). Forgotten tmpfs mounts are a classic stealth memory consumer.
- **buff/cache: 12Gi** — reclaimable file cache. The kernel will hand this back the moment a process needs RAM.
- **available: 11Gi** — **the only number that matters for capacity planning.** This is what's realistically available to new allocations without swapping. Roughly equals `free + reclaimable cache`.

**Swap line:** 1.4Gi used. Not inherently bad. The question is whether it's *growing* and whether the system is *actively swapping*. `free` is a snapshot — it cannot tell you that. Use `vmstat` for the trend.

### Red flags in `free` output

- `available` under ~10% of total → real pressure
- `available` near zero AND swap near full → OOM is imminent
- `shared` unexpectedly large → check `df -h -t tmpfs` for forgotten mounts
- `buff/cache` near zero on a busy server → something is forcing cache eviction (large anonymous allocations or `drop_caches` misuse)

---

## 4. Tool: `/proc/meminfo`

The raw source. `free` is a thin wrapper around this file. Read `/proc/meminfo` when you need detail `free` hides.

```bash
cat /proc/meminfo
```

### Sample Output (abbreviated)

```
MemTotal:       32827384 kB
MemFree:          421380 kB
MemAvailable:   11284192 kB
Buffers:          892140 kB
Cached:         11342108 kB
SwapCached:        48720 kB
Active:         14821664 kB
Inactive:        7102488 kB
Active(anon):    9744120 kB
Inactive(anon):   408240 kB
Active(file):    5077544 kB
Inactive(file):  6694248 kB
Unevictable:       18432 kB
Mlocked:           18432 kB
SwapTotal:       8388604 kB
SwapFree:        6952316 kB
Dirty:             24416 kB
Writeback:             0 kB
AnonPages:       9669820 kB
Mapped:           742160 kB
Shmem:           1284812 kB
KReclaimable:     742108 kB
Slab:             982344 kB
SReclaimable:     742108 kB
SUnreclaim:       240236 kB
KernelStack:       28480 kB
PageTables:       102348 kB
CommitLimit:    24802296 kB
Committed_AS:   18441208 kB
HugePages_Total:       0
HugePages_Free:        0
Hugepagesize:       2048 kB
```

### Interpretation of the fields that matter

**The capacity numbers:**
- `MemAvailable` — same as `free`'s available column. Trust this.
- `Active` / `Inactive` — kernel LRU lists. Inactive pages are next in line for eviction. Big `Inactive(file)` is healthy: lots of cold cache the kernel can drop instantly.

**The anonymous numbers (process memory):**
- `AnonPages` — total anonymous memory in use. This grows with leaks.
- `Shmem` — POSIX shared memory and tmpfs. **Counted as anonymous-like for swap purposes** but won't show in individual process RSS in an obvious way.
- `Mapped` — file pages currently mapped by processes (shared libs, mmap'd files).

**Swap and dirty data:**
- `SwapCached` — pages that have been swapped out but are also still in RAM. Free win: if the process touches them, no disk read needed.
- `Dirty` — modified pages waiting to be written to disk. **Large and growing Dirty + slow disk = stalled writes and memory pressure.** Tune `vm.dirty_ratio` / `vm.dirty_background_ratio` if this is chronic.
- `Writeback` — currently being written. Non-zero is normal during flushes.

**Kernel's own memory:**
- `Slab` — kernel object caches (inodes, dentries, network buffers). `SReclaimable` can be dropped under pressure; `SUnreclaim` cannot. **Growing `SUnreclaim` over days = kernel-side leak.** Drill in with `slabtop`.
- `KernelStack` — one stack per thread. Runaway thread creation shows up here.
- `PageTables` — memory used to track virtual→physical mappings. Tens of MB normal; hundreds of MB suggests many processes mapping huge address spaces (databases with many connections are a classic case — investigate THP/hugepages).

**Commit accounting:**
- `CommitLimit` — the kernel's overcommit ceiling (`RAM * overcommit_ratio / 100 + swap`, when `overcommit_memory=2`).
- `Committed_AS` — total virtual memory the kernel has promised to processes. When this approaches `CommitLimit`, new `malloc()` calls start failing with ENOMEM even though RAM looks free. Mostly relevant when overcommit is disabled.

**HugePages:**
- `HugePages_Total` of 0 means none reserved. Large databases (Oracle, Postgres with `huge_pages=on`) need these explicitly allocated via `vm.nr_hugepages`.

---

## 5. Tool: `vmstat`

`free` is a photo. `vmstat` is a video. Use it to see whether the system is *currently* under pressure.

```bash
vmstat 1 10
```

The first row is averages since boot — **ignore it**. Watch rows 2+.

### Sample Output — Healthy System

```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 1  0  1432  421380 892140 11342108   0    0     8    24  148  312  4  1 94  1  0
 2  0  1432  418240 892140 11343224   0    0     0     0  201  402  6  1 93  0  0
 1  0  1432  415108 892140 11344340   0    0     0    16  189  378  5  1 94  0  0
```

`si` and `so` are zero. `wa` (I/O wait) is near zero. `r` (run queue) ≤ CPU count. **This system is fine.**

### Sample Output — System Under Memory Pressure

```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 4  3 4821044  98412  21408  482104 1840 2104  4288  5120 8124 12048 18 12 22 48  0
 6  4 4892108  92108  18244  448120 2008 2480  5120  6240 9248 13420 22 14 16 48  0
 5  5 4961240  88240  16108  421044 2240 2680  6144  7360 9824 14108 19 16 14 51  0
```

This is a classic memory crisis:

- `swpd` is large and climbing (4.8 GB → 4.9 GB → 4.96 GB) — swap usage growing
- `si` and `so` are both non-zero and high — **the system is actively swapping in and out simultaneously, the textbook definition of thrashing**
- `bi`/`bo` are elevated — the swap traffic is hammering disk
- `wa` (I/O wait) is around 50% — half the CPU's time is spent waiting on disk
- `b` (blocked on I/O) is consistently 3+ — processes stuck waiting

**Diagnosis:** working set exceeds RAM. Either kill the hog, add RAM, or accept performance loss.

### Column reference

- **r** — processes waiting for CPU. Should be ≤ core count.
- **b** — processes in uninterruptible sleep (usually disk). Sustained >0 means I/O bottleneck.
- **swpd** — total swap used (kB).
- **free, buff, cache** — same as `free`.
- **si** — kB/s swapped *in* from disk. **Any sustained non-zero value is bad.**
- **so** — kB/s swapped *out* to disk. Brief bursts are normal during memory pressure; sustained values are thrashing.
- **bi, bo** — block I/O in/out (kB/s).
- **in, cs** — interrupts and context switches per second. High values during memory pressure indicate the scheduler is fighting itself.
- **wa** — CPU time waiting on I/O.

### Useful variants

```bash
vmstat -s              # Static summary, broken down by event counters
vmstat -d              # Per-disk I/O stats
vmstat -w 1            # Wider columns (easier on the eyes for large numbers)
vmstat -a 1            # Show Active/Inactive instead of buff/cache
```

---

## 6. Tool: `top` and `htop`

Live process view. `top` is everywhere; `htop` is friendlier when you can install it.

### `top` for memory

Launch `top`, then press:
- **`M`** — sort by `%MEM` (RSS)
- **`e`** — toggle memory units (KiB → MiB → GiB)
- **`f`** — choose columns; add `RES`, `SHR`, `SWAP`, `%MEM`, `OOMs`

### Sample Header

```
top - 14:23:48 up 12 days,  3:42,  2 users,  load average: 4.21, 3.88, 3.42
Tasks: 412 total,   2 running, 410 sleeping,   0 stopped,   0 zombie
%Cpu(s): 18.2 us, 12.4 sy,  0.0 ni, 22.1 id, 47.0 wa,  0.0 hi,  0.3 si,  0.0 st
MiB Mem :  32058.0 total,    411.4 free,  18420.8 used,  13225.8 buff/cache
MiB Swap:   8192.0 total,   6952.3 free,   1239.7 used.  11024.4 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   3128 postgres  20   0   12.4g   6.8g   4.2g S  18.4  21.7  1842:14 postgres
   4821 java      20   0   18.2g   4.1g  24640 S  22.0  13.1   924:48 java
   2104 mysql     20   0    8.4g   2.8g   8192 S   8.4   8.9   612:32 mysqld
```

### Interpretation

- `load average: 4.21, 3.88, 3.42` — climbing. Combined with `wa: 47.0`, this load is I/O-driven.
- Memory header matches `free`: 411 MiB truly free, 11 GiB available, swap 1.2 GiB used.
- **Process list:** sort by `%MEM` to find consumers, but watch for two traps:

**Trap 1: VIRT is misleading.** Java processes routinely show 10+ GiB of VIRT because the JVM reserves a huge heap address range. RES is the real number.

**Trap 2: RES double-counts shared memory.** Postgres above shows 6.8 GiB RES and 4.2 GiB SHR. The 4.2 GiB is shared buffers used by *every* postgres backend. Summing RES across all postgres workers will inflate the total wildly. Use PSS (next sections) for accuracy.

### `htop` tips

- `F6` — sort menu (pick `PERCENT_MEM` or `M_RSS`)
- `F2` → Setup → Display options → enable "Detailed CPU time" and the meter "Memory" / "Swap"
- The memory bar shows: green (used), blue (buffers), yellow (cache). If it's mostly green with thin yellow, cache is starved.

---

## 7. Tool: `ps` for Memory Hunting

`ps` is scriptable and precise. Use this when you need a sortable list to grep or pipe.

```bash
ps -eo pid,user,pri,ni,vsz,rss,pmem,stat,comm --sort=-rss | head -15
```

### Sample Output

```
    PID USER     PRI  NI    VSZ   RSS %MEM STAT COMMAND
   3128 postgres  20   0 12998144 7138304 21.7 Ss  postgres
   4821 java      20   0 19087360 4298752 13.1 Sl  java
   2104 mysql     20   0  8806400 2937856  8.9 Ssl mysqld
   8912 nginx     20   0   142080  98432  0.3 S    nginx
   9104 redis     20   0   421120  82048  0.2 Ssl  redis-server
```

VSZ and RSS are in KiB. Multiply by 1024 for bytes, or divide by 1024 for MiB.

### Useful one-liners

**Total RSS by user:**
```bash
ps -eo user,rss --no-headers | awk '{a[$1]+=$2} END {for (u in a) printf "%-15s %10.1f MiB\n", u, a[u]/1024}' | sort -k2 -n
```

**All processes of a single binary, summed:**
```bash
ps -C postgres -o rss --no-headers | awk '{s+=$1} END {print s/1024 " MiB"}'
```

⚠️ This sum **over-counts** shared memory. Postgres workers share buffers; the real consumption is much less than this number. See `smem` for the honest answer.

**Show command line (long):**
```bash
ps -eo pid,rss,args --sort=-rss | head
```

Often the process name alone is useless (a hundred `python` processes); `args` shows what they're actually running.

---

## 8. Tool: `smem` for Accurate Per-Process Usage

`ps` and `top` overstate memory because RSS counts shared pages once per process. `smem` reads `/proc/<pid>/smaps` and reports **PSS** (proportional) and **USS** (unique).

Install: `apt install smem` / `dnf install smem`.

```bash
smem -tk -s pss
```

### Sample Output

```
  PID User     Command                         Swap      USS      PSS      RSS
 8912 nginx    nginx: worker process              0      8.4M     9.1M    18.4M
 9104 redis    /usr/bin/redis-server              0     74.2M    78.0M    82.0M
 2104 mysql    /usr/sbin/mysqld                   0    1.8G     2.1G     2.8G
 4821 java     /usr/bin/java -Xmx4g -jar          0    3.9G     4.0G     4.1G
 3128 postgres postgres: 14/main                  0     1.2G     2.4G     6.8G
 3142 postgres postgres: writer                   0     48.0M    1.8G     6.4G
 3148 postgres postgres: walwriter                0     32.0M    1.7G     6.3G
-------------------------------------------------------------------------------
  412                                             0    14.2G    18.4G    44.2G
```

### Interpretation

The postgres backends are the perfect example:
- **RSS column sums to ~20 GiB across the postgres rows alone** — but the server only has 32 GiB total. Impossible? No — RSS is lying. Each backend's RSS includes the shared 4 GiB buffer pool.
- **PSS column** divides shared pages by the number of processes sharing them. The postgres backends now sum to a much more reasonable number that reflects reality.
- **USS column** shows only memory unique to each process. If you killed postgres backend 3148 right now, you'd reclaim ~32 MiB (its USS), not its 6.3 GiB RSS.

**Rule of thumb:**
- Use **PSS** when asking "how much memory does this *application* (group of processes) really use?"
- Use **USS** when asking "how much would I free by killing this *specific* process?"
- Use **RSS** when asking "what's the kernel's view of this process's physical footprint right now?"

### Other useful smem invocations

```bash
smem -uk                  # Group by user
smem -wk                  # System-wide breakdown (userspace, kernel, free)
smem -P postgres -tk      # Filter by command pattern
smem --pie name -c "pss"  # Pie chart (with --x11) — surprisingly useful
```

---

## 9. Tool: `/proc/<pid>/` Deep Dive

When you've identified a suspect process, `/proc/<pid>/` has the full picture.

### `status` — the human-readable summary

```bash
cat /proc/3128/status | grep -E '^Vm|^Rss|^Threads'
```

```
VmPeak:  13002240 kB
VmSize:  12998144 kB
VmLck:         0 kB
VmPin:         0 kB
VmHWM:   7142400 kB
VmRSS:   7138304 kB
RssAnon:  2924032 kB
RssFile:    72128 kB
RssShmem: 4142144 kB
VmData:  2980864 kB
VmStk:       136 kB
VmExe:      7720 kB
VmLib:     21048 kB
VmPTE:     16480 kB
VmSwap:        0 kB
Threads:        8
```

- **VmPeak** — high-water mark of VmSize. If VmPeak >> VmSize, the process *was* huge and freed memory back to the kernel.
- **VmHWM** — high-water mark of VmRSS. If VmHWM is close to total RAM and VmRSS now lower, you had a spike — investigate logs from that time.
- **RssAnon / RssFile / RssShmem** — RSS broken into anonymous (heap), file-backed (libraries, mmap'd files), and shared memory. **A growing RssAnon over time is the signature of a heap leak.**
- **VmData** — data segment size (heap + initialized data). Tracks roughly with RssAnon for non-mmap-heavy apps.
- **VmSwap** — pages this process has in swap. Non-zero here while system swap is "used" tells you whose pages are out there.
- **Threads** — runaway thread creation shows up here. Each thread takes ~8 MiB of VmSize for its stack by default.

### `smaps_rollup` — the cheap summary

```bash
cat /proc/3128/smaps_rollup
```

```
55c8a4a00000-7ffeb8021000 ---p 00000000 00:00 0 [rollup]
Rss:             7138304 kB
Pss:             2412800 kB
Pss_Anon:        2924032 kB
Pss_File:           8704 kB
Pss_Shmem:       -519936 kB  (negative due to rounding in some kernels; ignore sign)
Shared_Clean:    4068864 kB
Shared_Dirty:      73216 kB
Private_Clean:     21048 kB
Private_Dirty:   2975176 kB
Swap:                  0 kB
SwapPss:               0 kB
```

`smaps_rollup` is the cheap way to get PSS for one process without parsing the entire `smaps` file (which can be megabytes for large processes).

- **Private_Dirty** — memory only this process touched and modified. **This is what dies with the process.** Equivalent to USS for anonymous memory.
- **Shared_Clean** — read-only shared library code and mmap'd files. Free to the kernel; killing the process doesn't reclaim it (other processes still reference it).
- **Shared_Dirty** — shared memory segments that have been written to (Postgres buffers, etc.).

### `smaps` — the full mapping list

```bash
less /proc/3128/smaps
```

Each entry looks like:

```
7f3e2c000000-7f3e2cd00000 rw-p 00000000 00:00 0 
Size:              13312 kB
KernelPageSize:        4 kB
MMUPageSize:           4 kB
Rss:               12480 kB
Pss:               12480 kB
Shared_Clean:          0 kB
Shared_Dirty:          0 kB
Private_Clean:         0 kB
Private_Dirty:     12480 kB
...
VmFlags: rd wr mr mw me ac sd
```

Use this when you need to find *which* mapping is growing. Common patterns:
- A heap allocator (glibc) lives in `[heap]`-named anonymous mappings.
- Native libraries that mmap large data files show as `r--s` (read-only shared) of a specific path.
- A leaking native lib will show as a growing anonymous `rw-p` mapping near the heap.

---

## 10. Tool: `slabtop` (Kernel Memory)

When RAM is used but no process owns it (`free` shows lots used, but `ps` sum is small), the kernel is holding it. `slabtop` shows what.

```bash
sudo slabtop -o -s c
```

`-o` is one-shot (no live update), `-s c` sorts by cache size.

### Sample Output

```
 Active / Total Objects (% used)    : 4218840 / 4421008 (95.4%)
 Active / Total Slabs (% used)      : 124820 / 124820 (100.0%)
 Active / Total Caches (% used)     : 102 / 142 (71.8%)
 Active / Total Size (% used)       : 1024800.42K / 1082240.18K (94.7%)
 Minimum / Average / Maximum Object : 0.01K / 0.24K / 16.00K

  OBJS ACTIVE  USE OBJ SIZE  SLABS OBJ/SLAB CACHE SIZE NAME
 824320 821048  99%    0.57K  29440       28    470528K radix_tree_node
 612480 612120  99%    1.00K  19140       32    612480K ext4_inode_cache
 482140 481208  99%    0.19K  22960       21     91840K dentry
 198410 197840  99%    0.12K   5980       33     23920K kernfs_node_cache
  82480  82408  99%    0.50K   2580       32     41280K kmalloc-512
```

### Interpretation

- **`ext4_inode_cache`: 612 MB** — inode metadata for ext4 files. Big number if you have millions of files. Drops automatically under pressure.
- **`dentry`: 92 MB** — directory entry cache (path lookups). Same story.
- **`radix_tree_node`: 470 MB** — used by the page cache to index pages. Large here because page cache is large.
- These are mostly `SReclaimable` — the kernel can free them on demand.

**Red flag patterns:**
- An obscure cache (anything you don't recognize) climbing into GB territory over days → suspect kernel module leak. Check `lsmod` and recent module loads.
- `kmalloc-*` caches sitting at GB and growing → general kernel allocation leak. Often points at a buggy driver. Cross-reference with `/proc/meminfo`'s `SUnreclaim`.

Force a cache drop (testing only — never on a busy production box without reason):

```bash
sync; echo 3 > /proc/sys/vm/drop_caches
```

After this, `Buffers`, `Cached`, and reclaimable slab drop to near zero. Anything *still* held is leaked or pinned.

---

## 11. Tool: `pmap`

Shows the memory map of a process in a friendly format. Useful for spotting unusual mappings.

```bash
pmap -x 3128 | tail -30
```

### Sample Output

```
Address           Kbytes     RSS   Dirty Mode  Mapping
000055c8a4a00000    7720    4824       0 r-xp  /usr/lib/postgresql/14/bin/postgres
000055c8a51c4000     264     264       0 r--p  /usr/lib/postgresql/14/bin/postgres
000055c8a5206000      88      88      80 rw-p  /usr/lib/postgresql/14/bin/postgres
000055c8a721c000    2192    2104    2104 rw-p  [heap]
00007f3e00000000 4194304 4142144 4142144 rw-s  /SYSV0052e2c1 (deleted)
00007f3f04000000   65536      24      24 rw-p  [anon]
...
00007ffeb7f00000     132      80      80 rw-p  [stack]
00007ffeb8019000      16       0       0 r--p  [vvar]
00007ffeb801d000       8       4       0 r-xp  [vdso]
ffffffffff600000       4       0       0 --xp  [vectors]
---------------- ------- ------- -------
total kB         12998144 7138304 7142224
```

### Interpretation

- **`r-xp` mappings** of binaries and `.so` files — executable code, read-only, shared. RSS shows how much was actually paged in.
- **`[heap]`** — main allocator region. A constantly-growing heap is the smoking gun for a malloc leak.
- **`/SYSV...`** — SysV shared memory segment (Postgres shared buffers here). 4 GiB region, almost entirely resident and dirty. Shared across all postgres backends.
- **`[anon]` regions** — anonymous mmaps. Modern allocators (glibc with `MALLOC_ARENA_MAX`, jemalloc, tcmalloc) use these instead of the classic heap. **Many `rw-p` anonymous mappings of identical size = glibc per-thread arenas.** If you see dozens of 65 MiB anon mappings, set `MALLOC_ARENA_MAX=2` and watch RSS drop.
- **`[stack]`** — main thread stack. Each additional thread gets its own stack mapping.

### `(deleted)` mappings — a real-world gotcha

If you see `(deleted)` on a file-backed mapping:

```
00007f3e2c000000  102400   98432   12480 rw-p  /var/log/app.log (deleted)
```

The process has a file open (often a log) that was deleted on disk. **Disk space won't be freed until the process closes the file or restarts.** A frequent cause of "df shows 100% but du shows almost nothing." Find the culprit with:

```bash
lsof +L1
```

---

## 12. Swap Analysis

### Is the swap being used at all?

```bash
swapon --show
```

```
NAME      TYPE      SIZE   USED PRIO
/dev/sda3 partition   8G   1.4G   -2
/swapfile file        4G     0B   -3
```

### Who is using swap?

```bash
for pid in $(ls /proc/ | grep -E '^[0-9]+$'); do
    swap_kb=$(awk '/^VmSwap:/ {print $2}' /proc/$pid/status 2>/dev/null)
    if [ -n "$swap_kb" ] && [ "$swap_kb" -gt 0 ]; then
        cmd=$(tr '\0' ' ' < /proc/$pid/cmdline | head -c 80)
        swap_mb=$(awk -v kb="$swap_kb" 'BEGIN { printf "%.1f", kb/1024 }')
        printf "%8s MB  PID %5d  %s\n" "$swap_mb" "$pid" "$cmd"
    fi
done | sort -n -r | head -20
```

### Sample Output

```
   470.8 MB  PID  4821  java -Xmx4g -jar app.jar
   144.7 MB  PID  3128  postgres: 14/main
    82.4 MB  PID  2104  /usr/sbin/mysqld
    24.2 MB  PID 18420  /usr/bin/python3 worker.py
     7.9 MB  PID  1240  /usr/lib/systemd/systemd-journald
```

### Interpretation

**Swap *used* is not swap *thrashing*.** A process with 500 MB in swap that the kernel paged out three days ago during a backup, and which has been running fine ever since, is not a problem — those are cold pages. The cost of pulling them in only matters if the process actually accesses them.

**Real swap problems** show up in `vmstat`'s `si`/`so` columns (active swapping right now), not in absolute swap usage.

### `vm.swappiness`

`/proc/sys/vm/swappiness` (0–200, default 60) controls how aggressively the kernel prefers swapping anonymous pages vs evicting page cache.

- **60 (default)** — balanced; fine for desktops.
- **10** — typical for database servers; keep anonymous memory resident, sacrifice cache.
- **1** — almost-never swap; use only with enough RAM that you truly don't need it.
- **0** — only swap to avoid OOM. Modern kernels still allow this; older kernels (pre-3.5) interpreted 0 differently.
- **100+** — favor swapping anonymous over evicting cache. Useful when cache hit rate matters more than process responsiveness.

```bash
sysctl vm.swappiness=10                              # Temporary
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf # Persistent
```

### zswap / zram

Compressed in-memory swap. Significantly faster than disk swap.

Check zswap:
```bash
cat /sys/module/zswap/parameters/enabled       # Y or N
cat /sys/kernel/debug/zswap/stored_pages       # Pages held compressed
```

Check zram:
```bash
zramctl
```

On systems with no spinning disk and where you can't add RAM, zram-backed swap is often the right answer for absorbing infrequent overflows.

---

## 13. The OOM Killer

When all memory and swap are exhausted and the kernel can't reclaim more, it picks a process and kills it. This is the OOM (out-of-memory) killer.

### Did the OOM killer fire?

```bash
dmesg -T | grep -i -E 'killed process|out of memory|oom'
journalctl -k --since "1 hour ago" | grep -i oom
```

### Sample OOM Log

```
[Tue May 19 09:42:18 2026] postgres invoked oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE), order=0, oom_score_adj=0
[Tue May 19 09:42:18 2026] CPU: 4 PID: 3128 Comm: postgres Not tainted 6.5.0-21-generic #21-Ubuntu
[Tue May 19 09:42:18 2026] Call Trace:
[Tue May 19 09:42:18 2026]  dump_stack_lvl+0x47/0x60
[Tue May 19 09:42:18 2026]  dump_header+0x4a/0x230
[Tue May 19 09:42:18 2026]  oom_kill_process.cold+0xb/0x10
[Tue May 19 09:42:18 2026] Mem-Info:
[Tue May 19 09:42:18 2026] active_anon:7842104 inactive_anon:402144 ... free:42180 free_pcp:0 free_cma:0
[Tue May 19 09:42:18 2026] Node 0 DMA32 free:32180kB min:30240kB low:37800kB high:45360kB ...
[Tue May 19 09:42:18 2026] Tasks state (memory values in pages):
[Tue May 19 09:42:18 2026] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[Tue May 19 09:42:18 2026] [   948 ]     0   948    24820     2480    98304        0             0 systemd-journal
[Tue May 19 09:42:18 2026] [  4821 ]  1000  4821  4771840  1074816  9633792    24820             0 java
[Tue May 19 09:42:18 2026] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,mems_allowed=0,global_oom,task_memcg=/user.slice/user-1000.slice/session-2.scope,task=java,pid=4821,uid=1000
[Tue May 19 09:42:18 2026] Out of memory: Killed process 4821 (java) total-vm:19087360kB, anon-rss:4299264kB, file-rss:0kB, shmem-rss:0kB, UID:1000 pgtables:9408kB oom_score_adj:0
```

### Interpretation

Read it bottom-up:

- **"Killed process 4821 (java) total-vm:19087360kB, anon-rss:4299264kB"** — the victim. Java, ~4.3 GiB resident anonymous memory.
- **"oom-kill:constraint=CONSTRAINT_NONE,...global_oom"** — system-wide OOM (not a cgroup limit). The whole machine ran out of RAM.
- **The task list** in the middle shows every process and its `oom_score_adj`. The kernel computes an `oom_score` from RSS + adjustments and picks the highest.
- **"postgres invoked oom-killer"** — postgres made the allocation that triggered OOM, but postgres was *not* the one killed. The invoker and the victim are typically different.
- **"Node 0 DMA32 free:32180kB min:30240kB"** — free memory in this zone was right at the minimum watermark. The kernel had no slack.

### Tuning OOM behavior

Protect a critical process from the OOM killer:

```bash
echo -1000 > /proc/<pid>/oom_score_adj
```

Values range from -1000 (never kill) to +1000 (kill first). Anything ≤ -1000 disables OOM killing for that process. Useful for SSH daemons (don't lock yourself out!) and monitoring agents.

systemd unit example:

```ini
[Service]
OOMScoreAdjust=-900
```

Watch the current scores:

```bash
for pid in $(pgrep -d ' ' sshd); do
    printf "PID %5d  score_adj=%5s  score=%s\n" \
        "$pid" "$(cat /proc/$pid/oom_score_adj)" "$(cat /proc/$pid/oom_score)"
done
```

### Disabling overcommit

For sensitive workloads (databases) you may want `malloc()` to fail rather than succeed-then-OOM-kill-something later:

```bash
sysctl vm.overcommit_memory=2
sysctl vm.overcommit_ratio=80
```

This sets `CommitLimit = RAM * 80% + Swap`. Once `Committed_AS` exceeds this, `malloc` returns NULL. Applications that handle ENOMEM gracefully prefer this; applications that don't will crash on the failed allocation instead of being OOM-killed.

---

## 14. Cgroups v2 Memory Limits (Containers)

Container OOMs are local: a container can be killed for hitting its limit while the host has 100 GiB free. Always check cgroup limits when troubleshooting containerized workloads.

### Find a container's cgroup

```bash
cat /proc/<pid>/cgroup
```

```
0::/system.slice/docker-7a3f8c2e9b1d4f5e6a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f.scope
```

### Read memory stats for that cgroup

```bash
CG=/sys/fs/cgroup/system.slice/docker-7a3f8c2e9b1d4f5e6a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f.scope

cat $CG/memory.current     # Current usage in bytes
cat $CG/memory.max         # Hard limit (or "max" if unlimited)
cat $CG/memory.high        # Throttling threshold (soft limit)
cat $CG/memory.swap.current
cat $CG/memory.swap.max
cat $CG/memory.events      # Counters: low, high, max, oom, oom_kill
cat $CG/memory.stat        # Detailed breakdown
```

### Sample `memory.events`

```
low 0
high 142
max 4
oom 1
oom_kill 1
```

- `high 142` — the cgroup hit `memory.high` 142 times and was throttled. **Throttling is a warning, not a kill.** The process is slowed by reclaim pressure.
- `max 4` — hit the hard limit 4 times.
- `oom_kill 1` — the cgroup OOM killer fired once. Check `dmesg` for the specifics; it'll show `task_memcg=...` pointing back to this cgroup.

### Sample `memory.stat` (abbreviated)

```
anon 2147483648
file 524288000
kernel_stack 16777216
slab 41943040
sock 8388608
shmem 12582912
file_mapped 209715200
file_dirty 4194304
file_writeback 0
anon_thp 0
inactive_anon 1048576000
active_anon 1098907648
inactive_file 314572800
active_file 209715200
pgfault 8421042
pgmajfault 142
workingset_refault_anon 248
workingset_refault_file 1842
oom_kill 1
```

- `anon 2147483648` — 2 GiB of anonymous memory in the container. Compare to `memory.max`.
- `pgmajfault 142` — major page faults (had to go to disk). High and growing = thrashing.
- `workingset_refault_*` — pages that were evicted and then quickly needed again. Non-trivial values suggest the limit is too tight for the working set.

### Docker / Podman shortcuts

```bash
docker stats --no-stream
podman stats --no-stream
```

```
CONTAINER ID   NAME       CPU %   MEM USAGE / LIMIT   MEM %   NET I/O   BLOCK I/O   PIDS
7a3f8c2e9b1d   webapp     12.4%   2.1GiB / 4GiB       52.5%   ...       ...         48
```

---

## 15. Memory Leak Investigation Workflow

When RSS grows over time and never shrinks, you have a leak. Here's the workflow.

### Step 1: Confirm growth, don't assume it

Take samples over time. Don't trust eyeballing `top` once.

```bash
while true; do
    date +"%Y-%m-%d %H:%M:%S"
    ps -p <pid> -o pid,rss,vsz,etime,comm --no-headers
    awk '/^VmRSS/||/^VmData/||/^RssAnon/||/^VmSwap/' /proc/<pid>/status
    echo "---"
    sleep 300
done | tee leak-trace-$(date +%Y%m%d).log
```

If `VmRSS` and `RssAnon` rise monotonically over hours, you have a leak. If they oscillate, it's just normal workload behavior — not a leak.

### Step 2: Categorize — heap or mappings?

Look at `smaps_rollup`:

```bash
cat /proc/<pid>/smaps_rollup | grep -E 'Rss|Pss|Anon|Shared|Private'
```

- Growing `Private_Dirty` and `Pss_Anon` → heap leak (malloc/new).
- Growing `Shared_Dirty` → shared memory or mmap leak.
- Growing `Pss_File` → file mappings (perhaps not unmapping mmap'd files).

### Step 3: Find the growing mapping

Snapshot `smaps` at two points in time, diff them:

```bash
cp /proc/<pid>/smaps /tmp/smaps.t1
# ... wait an hour ...
cp /proc/<pid>/smaps /tmp/smaps.t2
diff /tmp/smaps.t1 /tmp/smaps.t2 | less
```

Mappings whose `Rss:` line grew significantly between snapshots are the leak sites. If they're anonymous (no path), it's the heap.

### Step 4: Reach for language-specific tools

- **C/C++:** `valgrind --tool=massif`, `valgrind --leak-check=full`, or run under `LD_PRELOAD=libtcmalloc.so` with `HEAPPROFILE=/tmp/heap`.
- **Java:** `jcmd <pid> GC.heap_info`, `jmap -histo:live <pid>`, full heap dump with `jmap -dump:live,format=b,file=heap.hprof <pid>`, analyzed in MAT or VisualVM. Don't forget to check off-heap with Native Memory Tracking (`-XX:NativeMemoryTracking=detail`).
- **Python:** `tracemalloc` (built-in), `pympler`, or `memray` for production-friendly profiling.
- **Go:** `runtime/pprof` (heap profile via `/debug/pprof/heap`).
- **Node.js:** `--inspect` + Chrome DevTools heap snapshot, or `clinic.js heapprofiler`.

### Step 5: The glibc arena trick (often-overlooked false positive)

Multi-threaded C/C++ programs using glibc malloc can show inflated RSS because glibc creates one arena per CPU thread by default. Each arena holds free memory that's not returned to the kernel.

```bash
MALLOC_ARENA_MAX=2 ./myapp
```

Or, on a running process, try a manual trim via gdb (use cautiously on production):

```bash
gdb --batch --pid=<pid> -ex 'call (int)malloc_trim(0)'
```

If RSS drops significantly, you didn't have a leak — you had arena fragmentation. Switching to jemalloc or tcmalloc often helps more permanently.

---

## 16. Tuning Knobs in `/proc/sys/vm/`

The most commonly touched sysctls. Persist them in `/etc/sysctl.d/99-tuning.conf`.

**`vm.swappiness` (0–200, default 60)** — controls preference for swapping anon vs evicting cache. Lower = keep anon resident. Set to 10 for most server workloads.

**`vm.dirty_ratio` (default 20)** — max percent of available memory that can be dirty before writers must block to flush. Lower (e.g. 10) on systems with slow disks to smooth out write spikes.

**`vm.dirty_background_ratio` (default 10)** — percent of dirty memory at which background flushing kicks in. Always lower than `dirty_ratio`. Pair: `background=5`, `ratio=10` is gentler.

**`vm.vfs_cache_pressure` (default 100)** — how aggressively the kernel reclaims dentry/inode cache vs page cache. Lower (e.g. 50) on file servers where you want metadata cached. Higher (e.g. 200) when slab is bloated.

**`vm.overcommit_memory`** —
- `0` (default) — heuristic; allows reasonable overcommit
- `1` — always overcommit; `malloc` never fails. Used by Redis recommendations.
- `2` — strict; respects `CommitLimit`. `malloc` will fail before overcommitting.

**`vm.overcommit_ratio` (default 50)** — only used when `overcommit_memory=2`. `CommitLimit = RAM*ratio/100 + swap`.

**`vm.min_free_kbytes`** — reserve held back for emergency allocations (network buffers, etc.). Default is computed from RAM size. Raise on systems with lots of RAM under network-heavy load.

**`vm.zone_reclaim_mode`** — NUMA reclaim behavior. Default 0 is right for almost everyone; legacy guidance to set 1 is usually wrong on modern kernels.

**`vm.panic_on_oom`** — set to 1 if you'd rather have the kernel panic (and reboot, with `kernel.panic` set) than have the OOM killer pick a victim. Useful for tightly clustered services where a fast reboot is preferable to running with a critical process killed.

**`vm.drop_caches`** — write-only knob for testing:
- `1` — drop page cache
- `2` — drop slab (dentries/inodes)
- `3` — both

Don't habitually run `drop_caches` in production. It just makes the next set of requests slow. Use it once to *measure* what's leaked vs cached, then move on.

---

## 17. Common Scenarios and Fixes

### Scenario A: "Server says only 200 MB free out of 64 GB!"

**Likely:** Normal. The kernel has filled the rest with page cache. Check `available` from `free -h`; if it's healthy (say, >5%), there's nothing wrong.

**Show the user:** `free -h` output, and explain the `available` column.

### Scenario B: "App is slow, system feels sluggish, load average is high"

**Check first:** `vmstat 1 5`. If `wa` is high and `si`/`so` are non-zero, the box is swap-thrashing. Find the hog via `smem -tk -s pss`, then either restart it, kill it, or fix the leak.

### Scenario C: "Container keeps getting killed but the host has tons of memory"

**Cause:** cgroup memory limit, not host-wide OOM. Check `dmesg` for `task_memcg=` lines, check `memory.events` for the container, and either raise `memory.max` or fix the leak in the container.

### Scenario D: "Disk is full but `du` shows nothing"

**Cause:** Deleted file held open by a process (look for `(deleted)` in `/proc/<pid>/maps` or run `lsof +L1`). Restart or signal the holder to release the file handle (e.g. SIGHUP to syslog daemons).

### Scenario E: "RSS keeps growing but the app team says they're not leaking"

**Check:** glibc arena explosion (set `MALLOC_ARENA_MAX=2`), or off-heap leak in JVM (NMT), or `mmap`'d files not being unmapped. Snapshot-diff `smaps` to find the growing region.

### Scenario F: "We have lots of free RAM but `malloc` is failing"

**Cause:** Overcommit is strict (`vm.overcommit_memory=2`) and `Committed_AS` ≥ `CommitLimit`. Either raise `vm.overcommit_ratio`, add swap, or look at why processes are reserving so much virtual memory (often: too-large per-thread stack reservations, mmap of giant sparse files, or a JVM with absurd `-Xmx`).

### Scenario G: "Slab is enormous"

**Check:** `slabtop -o -s c`. If `dentry` or `*_inode_cache` dominates, the box has done a lot of file traversal (find, backup, rsync). The cache is reclaimable and will shrink under pressure. If unrelated kernel slabs grow without bound, suspect a module/driver leak; correlate with module loads in `dmesg`.

### Scenario H: "OOM killer killed the wrong thing"

**Fix:** Lower `oom_score_adj` for critical processes (sshd, your database) to make them last to be killed. Or set `vm.panic_on_oom=1` if you'd rather reboot than lose the wrong process.

---

## Appendix: Quick Reference Card

```
Snapshot:               free -h
Active pressure:        vmstat 1
Per-process accurate:   smem -tk -s pss
Process detail:         cat /proc/<pid>/status
                        cat /proc/<pid>/smaps_rollup
Kernel memory:          slabtop -o -s c
Memory map:             pmap -x <pid>
Swap users:             scan /proc/*/status for VmSwap
OOM history:            dmesg -T | grep -i oom
Container limits:       cat /sys/fs/cgroup/.../memory.{current,max,events,stat}
Drop caches (test):     echo 3 > /proc/sys/vm/drop_caches
Persistent tuning:      /etc/sysctl.d/99-*.conf

Numbers to trust:       MemAvailable, PSS, USS
Numbers to distrust:    free (column), VSZ, summed RSS

The four-command triage:
    free -h ; vmstat 1 5 ; dmesg -T | tail -50 ; ps aux --sort=-%mem | head
```
