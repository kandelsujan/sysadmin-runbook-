# Linux Memory Troubleshooting Guide

A practical playbook with real outputs, what's normal vs. what's a smoking gun, and how to interpret every number. Work through these steps top to bottom; each builds on what the previous one tells you.

## Table of Contents

1. [Get the lay of the land](#step-1-get-the-lay-of-the-land)
2. [Watch memory move in real time](#step-2-watch-memory-move-in-real-time)
3. [Find the top memory consumers](#step-3-find-the-top-memory-consumers)
4. [Inspect the suspect process](#step-4-inspect-the-suspect-process)
5. [Check for the OOM killer](#step-5-check-for-the-oom-killer)
6. [Cgroup / container memory](#step-6-cgroup--container-memory)
7. [Kernel-side consumers](#step-7-kernel-side-consumers)
8. [Page cache and dirty pages](#step-8-page-cache-and-dirty-pages)
9. [Swap-specific diagnostics](#step-9-swap-specific-diagnostics)
10. [Pressure Stall Information](#step-10-pressure-stall-information-best-system-wide-signal)
11. [Process-specific leak hunting](#step-11-process-specific-leak-hunting)
12. [Correlate with what changed](#step-12-correlate-with-what-changed)
13. [Quick triage flow](#quick-triage-flow)
14. [One-liner cheat sheet](#one-liner-cheat-sheet)

---

## Step 1: Get the lay of the land

```bash
free -h
```

**Healthy output:**
```
               total        used        free      shared  buff/cache   available
Mem:            31Gi       8.2Gi       2.1Gi       412Mi        21Gi        22Gi
Swap:          8.0Gi          0B       8.0Gi
```
Here `available` is 22Gi out of 31Gi total — plenty of room. `buff/cache` at 21Gi looks scary but is reclaimable. Swap untouched. This host is fine.

**Problem output:**
```
               total        used        free      shared  buff/cache   available
Mem:            31Gi        29Gi       180Mi       2.1Gi       1.8Gi       420Mi
Swap:          8.0Gi       7.6Gi       400Mi
```
Red flags: `available` is only 420Mi (1.3% of total), swap is 95% consumed, and `buff/cache` has collapsed to 1.8Gi because the kernel already evicted everything reclaimable. This host is in trouble.

**The decisive number is `available`, not `free`.** Ignore `free`. A healthy Linux system uses nearly all RAM for cache; `available` accounts for what can be reclaimed.

### Understanding every field in /proc/meminfo

```bash
cat /proc/meminfo
```

This is the master memory file. Every value is in KB unless noted. Here's what each field means and when to care about it.

**Top-level totals:**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `MemTotal` | Total usable RAM (excludes kernel binary and reserved regions). Fixed value. | Baseline for percentages. |
| `MemFree` | RAM not used for *anything* — neither processes nor cache. Misleading; ignore in favor of `MemAvailable`. | Only matters if approaching zero AND `MemAvailable` is also tiny. |
| `MemAvailable` | Estimated memory available for new allocations without swapping. Accounts for reclaimable cache and slab. **The number you actually care about.** | Critical when below ~5% of `MemTotal`. |
| `Buffers` | Temporary storage for raw block-device I/O (filesystem metadata, etc.). Usually small (<1 GB). | Rarely a problem; large values suggest heavy raw disk I/O. |
| `Cached` | Page cache: file contents read from disk. Reclaimable under pressure. | High values are normal and good. Sudden drops mean the kernel was forced to evict cache. |
| `SwapCached` | Pages that were swapped out, then read back, but kernel kept the swap copy. Avoids re-writing if evicted again. | Non-zero means the system has been swapping. Growing = active swap pressure. |

**Active vs inactive (the LRU lists):**

| Field | Meaning |
|-------|---------|
| `Active` | Recently used memory; kernel won't reclaim unless desperate. |
| `Inactive` | Less recently used; first candidates for reclaim. |
| `Active(anon)` | Active anonymous memory (heap, stack — not file-backed). |
| `Inactive(anon)` | Inactive anonymous memory; can only be reclaimed by swapping. |
| `Active(file)` | Active file-backed memory (page cache). |
| `Inactive(file)` | Inactive file-backed memory; cheapest to reclaim (just drop the page). |
| `Unevictable` | Memory that cannot be reclaimed (mlocked pages, ramfs, etc.). |
| `Mlocked` | Pages locked in RAM by `mlock()` system call. Usually small; large values suggest databases or security apps locking memory. |

**Why this split matters:** If `Inactive(file)` is large, the kernel has plenty of easy reclaim available — pressure isn't real yet. If reclaim is happening but only `Active(anon)` and `Inactive(anon)` are big, the kernel can only free memory by swapping, which is slow and painful.

**Swap:**

| Field | Meaning |
|-------|---------|
| `SwapTotal` | Total swap space configured. |
| `SwapFree` | Unused swap. `SwapTotal - SwapFree` = swap in use. |

**Anonymous, file-mapped, and shared memory:**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `AnonPages` | Anonymous memory (heap/stack) mapped into user processes. Not backed by any file. | This is what processes actually allocate. Growing without restarts = leak somewhere. |
| `Mapped` | File-backed memory currently mmap'd into processes (executables, libraries, mmap'd data files). | Usually stable. Large growth could mean apps mmap'ing huge files. |
| `Shmem` | Shared memory: tmpfs, `/dev/shm`, SysV shared memory, shared anonymous mmaps. **Counted as "used" but easy to miss.** | Often the culprit for "where did my RAM go?" Check `/dev/shm` size. |
| `KReclaimable` | Kernel allocations the kernel claims it can reclaim (includes `SReclaimable`). | High values mean kernel is happy to give memory back if asked. |

**Dirty and writeback (pending disk writes):**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `Dirty` | Modified pages waiting to be written to disk. | <100 MB normal. Multiple GB = slow disk or heavy writer; can cause I/O stalls. |
| `Writeback` | Pages currently being written to disk. | Should be small and transient. Sustained high values = disk can't keep up. |
| `WritebackTmp` | Temporary writeback buffers used by FUSE filesystems. | Only relevant on FUSE-heavy hosts. |
| `NFS_Unstable` | NFS pages sent to server but not yet committed. | Only relevant on NFS clients. Growing values = NFS server slow. |
| `Bounce` | "Bounce buffers" for old devices that can't DMA to high memory. | Modern hardware: always 0. |

**Memory commitment (overcommit accounting):**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `CommitLimit` | Total memory that can be allocated based on overcommit policy. Usually `swap + (RAM × overcommit_ratio / 100)`. | The hard ceiling. |
| `Committed_AS` | Total memory currently *promised* to all processes (whether actually used or not). | If `Committed_AS > MemTotal`, processes have promised more than physically exists. If it exceeds `CommitLimit` with `vm.overcommit_memory=2`, new allocations fail. |

**Kernel memory (slab):**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `Slab` | Total kernel slab allocator memory (data structures: dentries, inodes, network buffers, etc.). | A few hundred MB is normal. Multiple GB = something is wrong. |
| `SReclaimable` | Slab memory the kernel can reclaim (mostly dentry and inode caches). | If `Slab` is huge but mostly `SReclaimable`, you can live with it. |
| `SUnreclaim` | Slab memory the kernel **cannot** reclaim. | This is the dangerous one. Large `SUnreclaim` = kernel/driver leak. |
| `KernelStack` | Memory used by kernel stacks for all threads. ~16KB per thread. | High values = thousands of threads on the system. |
| `PageTables` | Memory used by the kernel to maintain virtual-to-physical mappings for all processes. | Over 1 GB on a normal host is unusual. Common with many JVMs or huge processes. |
| `SecPageTables` | Secondary page tables (used by KVM, IOMMU). | Only relevant on virtualization hosts. |

**Virtual memory areas (kernel address space):**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `VmallocTotal` | Total size of vmalloc area (kernel virtual address space). Architectural; fixed. | Almost never matters. |
| `VmallocUsed` | Kernel virtual memory currently used by `vmalloc()`. | Steady growth over time = kernel module leak. |
| `VmallocChunk` | Largest contiguous free block in vmalloc area. | Small values can prevent large kernel allocations. |
| `Percpu` | Per-CPU allocator memory. Scales with CPU count and subsystems. | Usually small. |

**Huge pages:**

| Field | Meaning | When it matters |
|-------|---------|-----------------|
| `AnonHugePages` | Anonymous memory backed by transparent huge pages (THP). | Normal on modern systems unless THP is disabled. |
| `ShmemHugePages` | Shared memory backed by THP. | Database tuning territory. |
| `ShmemPmdMapped` | Shared memory mapped using huge pages at the PMD level. | Database tuning territory. |
| `FileHugePages` | File-backed memory using huge pages. | Rare. |
| `FilePmdMapped` | File-backed memory mapped at the PMD level with huge pages. | Rare. |
| `HugePages_Total` | Reserved (explicit) huge pages, count not KB. Multiply by `Hugepagesize`. | Reserved at boot. If apps don't use them, this RAM is wasted. |
| `HugePages_Free` | Reserved huge pages not yet allocated. | If equal to `HugePages_Total`, nothing is using them. |
| `HugePages_Rsvd` | Huge pages promised to apps but not yet faulted in. | Normal. |
| `HugePages_Surp` | "Surplus" huge pages allocated beyond `HugePages_Total`. | Configured by `nr_overcommit_hugepages`. |
| `Hugepagesize` | Size of each huge page (typically 2048 KB = 2 MB). | Fixed by architecture/config. |
| `Hugetlb` | Total memory reserved for HugeTLB pages of all sizes. | Same as `HugePages_Total × Hugepagesize` in most setups. |

**Other:**

| Field | Meaning |
|-------|---------|
| `HardwareCorrupted` | RAM marked bad by ECC. Should always be 0. **Non-zero = failing RAM, replace hardware.** |
| `CmaTotal` / `CmaFree` | Contiguous Memory Allocator (mostly mobile/embedded). |
| `DirectMap4k` / `DirectMap2M` / `DirectMap1G` | How the kernel's direct mapping of physical RAM is split into page sizes. Diagnostic for memory fragmentation. |

### What to focus on first

When you `cat /proc/meminfo`, scan in this order:

1. **`MemAvailable`** — is it below 5% of `MemTotal`?
2. **`SwapFree`** — is swap being consumed?
3. **`Dirty`** — multiple GB pending writes?
4. **`SUnreclaim`** — multiple GB locked in kernel?
5. **`Committed_AS` vs `CommitLimit`** — is the system overcommitted?
6. **`AnonPages`** — growing without process restarts?
7. **`HardwareCorrupted`** — should be zero; anything else is a hardware failure.

### Diagnostic patterns

**Kernel-side leak signature:**
```
MemTotal:       32827456 kB
MemAvailable:    1240320 kB    ← very low
AnonPages:       4521008 kB    ← user memory normal
Slab:           18234560 kB    ← 17 GB in slab!
SReclaimable:     820480 kB
SUnreclaim:     17414080 kB    ← almost all unreclaimable
```
17 GB stuck in unreclaimable kernel slabs. User-process hunting won't find this — go to Step 7.

**Tmpfs / shared memory eating RAM:**
```
MemAvailable:    2104320 kB
AnonPages:       3201008 kB    ← processes only using 3 GB
Shmem:          22041008 kB    ← but 22 GB in shared memory!
Cached:         23241008 kB    ← (Shmem is counted inside Cached)
```
Check `df -h | grep tmpfs` and `ls -lh /dev/shm/`. Common cause: applications writing huge files into `/dev/shm`.

**Overcommit headed for OOM:**
```
MemTotal:       32827456 kB
CommitLimit:    24620592 kB
Committed_AS:   42018400 kB    ← processes promised 42 GB!
```
Processes have promised more memory than the kernel will allow. Next big allocation may fail or trigger OOM.

---

## Step 2: Watch memory move in real time

```bash
vmstat 2 5
```

**Healthy output:**
```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 1  0      0 2204312 184220 21458104  0    0     8    24  102  198  3  1 96  0  0
 0  0      0 2204188 184220 21458104  0    0     0     0   88  165  2  1 97  0  0
```
`si`/`so` are 0. `b` (blocked) is 0. `wa` (I/O wait) is 0. Idle and happy.

**Thrashing output:**
```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 4  8 7841200 180320  12044 184220 4820 6240 18432 24100 8204 11203 12 18  4 66  0
 2 11 7843180 178440  11820 182104 5104 6880 19200 25640 8920 12440 14 21  3 62  0
```
The story:
- `si`/`so` sustained in the thousands of KB/sec — pages flying in and out of swap
- `b` is 8-11 — many processes blocked on I/O
- `wa` is 60%+ — CPUs idle waiting for swap
- `swpd` near 8 GB — swap almost full

Textbook thrashing. Host feels frozen even though CPU shows "idle."

For longer-term trending:

```bash
sar -r 1 5
```

```
12:00:01    kbmemfree   kbavail   kbmemused  %memused  kbbuffers  kbcached  kbcommit   %commit
12:00:02       180432    520180    32647024     99.45      12044    184220   45820100   139.55
                                                ^^^^^                                    ^^^^^^
                                          memory full                          committed > total!
```
`%commit` above 100% means processes have collectively promised to use more memory than exists.

---

## Step 3: Find the top memory consumers

```bash
ps aux --sort=-rss | head -10
```

**Real output from a host with a leak:**
```
USER         PID %CPU %MEM    VSZ    RSS TTY    STAT START   TIME COMMAND
appuser    18420 92.4 71.2 28401204 22834520 ?   Sl   Mon14  847:22 /usr/bin/java -Xmx20g -jar app.jar
postgres    1842  2.1  6.8 4218032 2184320 ?    Ss   Jan01   42:18 postgres: main process
nginx      14820  0.1  0.4  92044  142208 ?     S    Mon14    0:42 nginx: worker process
```

How to read this:
- `%MEM` is percent of physical RAM. Java at 71.2% on a 32 GB box = 22.7 GB
- `RSS` is in KB. 22,834,520 KB = 22.8 GB actual physical memory
- `VSZ` (virtual size) being larger than RSS is normal for a JVM

Java is the prime suspect. But verify with PSS via `smem`.

### Understanding every column in smem

`smem` is the most honest per-process memory tool because it handles shared memory correctly. Install with `apt install smem` or `dnf install smem`.

```bash
sudo smem -tk -s pss | head -10
```

**Output:**
```
  PID User     Command                         Swap      USS      PSS      RSS
18420 appuser  /usr/bin/java -Xmx20g -jar a   1.2G    21.8G    21.9G    22.8G
 1842 postgres postgres: main process         24.0M     1.8G     1.9G     2.1G
14820 nginx    nginx: worker process           0       128.0M   135.2M   142.2M
-------------------------------------------------------------------------------
   42 1                                        1.2G    24.1G    24.3G    25.4G
```

**The four memory columns, in increasing order of "shared bookkeeping":**

| Column | Full name | Meaning |
|--------|-----------|---------|
| `Swap` | Swapped memory | How much of this process's memory currently lives in swap. Growing = memory pressure on this specific process. |
| `USS` | Unique Set Size | Memory that belongs **only** to this process. **This is what you'd reclaim if you killed it.** Pure private memory. |
| `PSS` | Proportional Set Size | USS + this process's fair share of shared memory. If 4 processes share a 100 MB library, each gets charged 25 MB. **The most honest "how much memory does this process really use" number.** PSS values across all processes sum to total used RAM. |
| `RSS` | Resident Set Size | USS + the **full** size of all shared memory used. Overcounts: if 10 processes share a library, all 10 are charged the full amount. Sum of RSS across processes is always greater than physical RAM. |

**Why this matters in practice:**

- Killing a process frees ~USS, not RSS. A process showing RSS=2GB but USS=200MB is mostly sharing memory; killing it barely helps.
- PSS is the only metric that sums correctly across all processes. If you want to allocate "blame" for total RAM usage, use PSS.
- The bigger the gap between USS and RSS, the more this process shares with others.

**Example interpretation:** A web server with 50 worker processes each showing RSS=200MB might only be using 250MB total — most of those 200MB are shared code/data. PSS for each worker would be ~5MB.

### Useful smem flavors

**Per-user totals:**
```bash
sudo smem -u
```
```
User     Count     Swap      USS      PSS      RSS
appuser     12     1.2G    21.9G    22.0G    22.9G
postgres     8    24.0M     1.7G     1.8G     2.1G
root        42    18.0M   240.0M   420.0M   840.0M
nginx        4        0   120.0M   135.0M   142.0M
```

**Per-mapping (which libraries are using the most):**
```bash
sudo smem -m -s pss | head
```
```
Map                                              PIDs   AVGPSS      PSS
[heap]                                              42    520.0M    21.8G
/usr/lib/jvm/java-17/lib/server/libjvm.so            1     180.M    180.M
[anon]                                              84      4.M    420.M
```
`[heap]` dominating at 21.8 GB confirms the JVM's own heap is the issue.

**With percentages:**
```bash
sudo smem -p
```
Shows USS/PSS/RSS as percentages of `MemTotal` — handy for quick sanity checks.

**Sorted by swap usage** (find what's been pushed out):
```bash
sudo smem -s swap -r | head
```

**System-wide summary:**
```bash
sudo smem -w
```
```
Area                           Used      Cache   Noncache
firmware/hardware                 0          0          0
kernel image                      0          0          0
kernel dynamic memory      18234560     820480   17414080
userspace memory           12420180    1840204   10579976
free memory                  420180     420180          0
```
Shows the global memory split into kernel dynamic, userspace, and free. The `Noncache` column for kernel dynamic memory is essentially `SUnreclaim` — useful for spotting kernel leaks at a glance.

**Without smem available**, fall back to ps but remember it shows RSS only:

```bash
ps -eo pid,user,rss,vsz,comm --sort=-rss | head -10
```

**Memory per user** with awk:

```bash
ps -eo user,rss --no-headers | \
  awk '{a[$1]+=$2} END {for (u in a) printf "%-15s %10.2f GB\n", u, a[u]/1024/1024}' | \
  sort -k2 -n -r
```
```
appuser              22.84 GB
postgres              2.18 GB
root                  0.84 GB
nginx                 0.14 GB
```

---

## Step 4: Inspect the suspect process

```bash
cat /proc/18420/status | grep -E '^Vm|^Rss'
```

**Output with field meanings:**
```
VmPeak:  28401204 kB    ← highest virtual size ever reached (lifetime max)
VmSize:  28401204 kB    ← current virtual size
VmLck:         0 kB     ← locked memory (mlock'd, can't be swapped)
VmHWM:  22834520 kB    ← highest physical RSS ever reached ("high water mark")
VmRSS:  22834520 kB    ← current resident memory
RssAnon:    21948032 kB    ← anonymous (heap/stack) memory
RssFile:       884488 kB    ← memory-mapped files (libraries, mmap'd data)
RssShmem:        2000 kB    ← shared memory (tmpfs, SysV)
VmData:  26840192 kB    ← data segment (heap lives here)
VmStk:        132 kB    ← stack
VmExe:         12 kB    ← executable text
VmLib:      18420 kB    ← shared library code
VmSwap:   1258204 kB    ← 1.2 GB of this process has been swapped out
```

**What to focus on:**
- `VmRSS == VmHWM` means RSS is at its all-time peak — process is still growing
- `RssAnon` being most of `VmRSS` confirms this is heap, not file cache
- `VmSwap` non-zero means the process is being forced to swap

**Track growth over time** (the definitive leak test):

```bash
while true; do
  echo "$(date +%H:%M:%S) RSS=$(awk '/VmRSS/{print $2}' /proc/18420/status) kB"
  sleep 60
done
```

**Output of a leak:**
```
14:00:12 RSS=18244520 kB
14:01:12 RSS=18402180 kB
14:02:12 RSS=18560044 kB
14:03:12 RSS=18718908 kB
14:04:12 RSS=18876012 kB
```
~158 MB/min growth, monotonic. That's a leak. Extrapolating: OOM in ~30 minutes.

**Breakdown of where the memory lives:**

```bash
sudo cat /proc/18420/smaps_rollup
```

**Output:**
```
560841aa3000-7ffd84020fff ---p 00000000 00:00 0     [rollup]
Rss:            22834520 kB
Pss:            21912080 kB
Pss_Anon:       21893120 kB    ← almost all anonymous memory
Pss_File:          18800 kB
Pss_Shmem:           160 kB
Shared_Clean:      14400 kB
Shared_Dirty:          0 kB
Private_Clean:      4200 kB
Private_Dirty:  22815920 kB    ← 22.8 GB of private dirty pages
Referenced:     22834520 kB
Anonymous:      21948032 kB
Swap:            1258204 kB
SwapPss:         1258180 kB
```

`Private_Dirty` of 22.8 GB tells you almost all the memory is private writes the process made itself. Nothing for the kernel to reclaim — only the process can free it.

---

## Step 5: Check for the OOM killer

```bash
sudo dmesg -T | grep -iE 'killed process|out of memory|invoked oom' | tail -20
```

**Output:**
```
[Tue May 26 09:14:22 2026] java invoked oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE), order=0, oom_score_adj=0
[Tue May 26 09:14:22 2026] Tasks state (memory values in pages):
[Tue May 26 09:14:22 2026] [  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[Tue May 26 09:14:22 2026] [   1842]   108  1842   529080   180420     2240512     2400        0 postgres
[Tue May 26 09:14:22 2026] [  14820]   33  14820    23044    35480      245760        0        0 nginx
[Tue May 26 09:14:22 2026] [  18420]  1000 18420  7100302  5870244    49807360   314420        0 java
[Tue May 26 09:14:22 2026] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),global_oom,task=java,pid=18420
[Tue May 26 09:14:22 2026] Out of memory: Killed process 18420 (java) total-vm:28401208kB, anon-rss:22834520kB, file-rss:884488kB, shmem-rss:8000kB
```

What this tells you:
- `java invoked oom-killer` — the Java process itself triggered OOM
- `total_vm` and `rss` columns (in **pages**, multiply by 4096) for every process at the moment of death
- Java's `rss × 4 KB = 23.5 GB`, vastly more than anyone else
- `constraint=CONSTRAINT_NONE` = global OOM. `CONSTRAINT_MEMCG` = cgroup hit its limit (jump to Step 6)
- `oom_score_adj=0` means no process was protected

**Check current OOM scores** (who's next):

```bash
for pid in $(ps -eo pid --no-headers); do
  [ -r /proc/$pid/oom_score ] && \
    printf "%6d %4s %s\n" "$pid" \
      "$(cat /proc/$pid/oom_score 2>/dev/null)" \
      "$(cat /proc/$pid/comm 2>/dev/null)"
done | sort -k2 -n -r | head -10
```

```
 18420 1842 java
  1842  142 postgres
 14820   18 nginx
```
Java at 1842 vs postgres at 142 — overwhelmingly next on the chopping block.

---

## Step 6: Cgroup / container memory

System-wide stats can look fine while one cgroup is suffocating. This is the #1 cause of "but the host has plenty of memory!" tickets.

```bash
sudo systemd-cgtop -m --order=memory -n 1
```

```
Control Group                            Tasks   %CPU   Memory  Input/s Output/s
docker/9f8a2c.../payment-service             24    4.2     7.9G        -        -
user.slice                                  142    1.8     2.1G        -        -
docker/c4b1e8.../redis                        4    0.4   412.0M        -        -
```

**The most valuable file: `memory.events`:**

```bash
cat /sys/fs/cgroup/docker/9f8a2c.../memory.events
```
```
low 0
high 14820
max 412
oom 28
oom_kill 12
```
- `low 0` — never breached `memory.low` (soft minimum)
- `high 14820` — hit `memory.high` (throttle threshold) 14,820 times
- `max 412` — hit `memory.max` (hard limit) 412 times
- `oom 28` — OOM situations triggered
- `oom_kill 12` — 12 processes killed inside this cgroup

This container is constantly being squeezed.

**The single most useful file: `memory.pressure`** (PSI for the cgroup):

```bash
cat /sys/fs/cgroup/docker/9f8a2c.../memory.pressure
```

```
some avg10=34.82 avg60=28.40 avg300=22.18 total=842180000
full avg10=18.20 avg60=14.80 avg300=10.92 total=420180000
```
- `some` line: % of time **at least one** task was stalled on memory
- `full` line: % of time **all** tasks were stalled simultaneously
- `avg10/60/300`: averages over the last 10/60/300 seconds
- `total`: cumulative microseconds stalled since boot

`some avg10=34.82` = tasks stalled 35% of the last 10 seconds. Double-digit values on `some avg60` is severe. `full` above ~5% means user-visible slowness.

**Healthy comparison:**
```
some avg10=0.00 avg60=0.02 avg300=0.04 total=420180
full avg10=0.00 avg60=0.00 avg300=0.00 total=18420
```

**Docker quick view:**
```bash
docker stats --no-stream
```
```
CONTAINER ID   NAME              CPU %    MEM USAGE / LIMIT      MEM %     NET I/O
9f8a2cd4b1e8   payment-service   4.20%    7.9 GiB / 8 GiB        98.75%   1.2 GB
c4b1e84a2810   redis             0.40%    412 MiB / 2 GiB        20.12%   42 MB
```
`payment-service` at 98.75% of limit — one allocation from OOM-kill.

---

## Step 7: Kernel-side consumers

```bash
sudo slabtop -o -s c | head -15
```

**Output of a dentry leak:**
```
 Active / Total Objects (% used)    : 42,184,200 / 42,820,100 (98.5%)
 Active / Total Size (% used)       : 18,840,220.42K / 19,420,180.18K (97.0%)

  OBJS ACTIVE  USE OBJ SIZE  SLABS OBJ/SLAB CACHE SIZE NAME
38420180 38400220  99%    0.19K 1830004     21  14640032K dentry
2418040 2400180  99%    1.05K  80604       30   2580128K inode_cache
1820040 1800020  98%    0.57K  65004       28   1040020K radix_tree_node
```

14 GB in `dentry`. Something is opening and closing files at a tremendous rate. Find it:

```bash
sudo lsof | awk '{print $1}' | sort | uniq -c | sort -rn | head -5
```
```
 1842048 myapp
   42180 nginx
    1820 postgres
```

`myapp` has 1.8 million file references. There's your dentry inflater.

```bash
grep -E 'VmallocUsed|KernelStack|PageTables' /proc/meminfo
```
```
VmallocUsed:    1840204 kB
KernelStack:      32480 kB
PageTables:     1240180 kB
```

Watch `VmallocUsed` over time. Steady growth without corresponding workload growth = kernel module leak.

---

## Step 8: Page cache and dirty pages

```bash
grep -E 'Dirty|Writeback' /proc/meminfo
```

**Normal:**
```
Dirty:              12048 kB
Writeback:              0 kB
```

**Problem:**
```
Dirty:           4820180 kB    ← 4.8 GB waiting to be written
Writeback:        820048 kB    ← 820 MB currently writing
```

If combined with high `wa` in `vmstat`, disk can't keep up. Find the writer:

```bash
sudo iotop -oP -d 2
```
```
Total DISK READ:    420.18 K/s | Total DISK WRITE:    142.18 M/s
  PID  PRIO  USER     DISK READ  DISK WRITE  COMMAND
18420 be/4 appuser    0.00 B/s   138.20 M/s  java -Xmx20g -jar app.jar
```

**Diagnostic cache-drop** (don't do this casually on production):

```bash
free -h
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
free -h
```

If `available` jumps massively (420Mi → 18Gi), the issue was cache pressure, not a leak. If it barely moves, real allocations are the problem.

---

## Step 9: Swap-specific diagnostics

Swap deserves its own section because "high swap usage" is one of the most misunderstood signals. Swap being **used** is not the same as swap being **active**. A process can have memory in swap that it never touches again — that's harmless. The dangerous pattern is constant page-in/page-out activity (thrashing).

### Where the swap lives

```bash
swapon --show
```
```
NAME      TYPE      SIZE   USED PRIO
/swap.img file       8G    7.6G   -2
/dev/sdc  partition  4G    1.2G   -3
```
Multiple swap devices with different priorities — the kernel fills higher-priority swap first. If you see swap on slow disks being heavily used, that alone explains poor performance.

### How active is the swapping?

```bash
vmstat 2 5
```
Watch the `si` and `so` columns (in KB/s, swap-in and swap-out):

| Pattern | Meaning |
|---------|---------|
| `si=0 so=0` consistently | Pages are in swap but nothing is moving. Harmless. |
| `si=0 so>0` occasionally | Kernel is pushing rarely-used pages out to free RAM. Normal. |
| `si>0 so=0` occasionally | Pages being read back as processes need them. Normal after a swap-out burst. |
| `si>0 AND so>0` sustained | **Thrashing.** Pages flying both directions. Catastrophic for performance. |

For a longer time-series view:

```bash
sar -W 2 10    # pages swapped in/out per second
sar -S 2 10    # swap utilization
```

```
12:00:01     pswpin/s pswpout/s
12:00:03      1240.00   1820.00    ← thousands of pages/sec both ways = thrashing
12:00:05      1180.00   1740.00
```

### Which processes are using swap?

This is what people actually want to know. The fastest way:

```bash
for f in /proc/*/status; do
  awk '/^Name:/{name=$2} /^Pid:/{pid=$2} /^VmSwap:/{if ($2+0 > 0) printf "%-25s PID=%-7s Swap=%s kB\n", name, pid, $2}' "$f"
done | sort -k4 -n -r | head -20
```

**Output:**
```
java                      PID=18420   Swap=1258204 kB
postgres                  PID=1842    Swap=240180 kB
chrome                    PID=8420    Swap=84200 kB
systemd-journald          PID=412     Swap=18204 kB
```

`VmSwap` per process tells you exactly how much of each process has been pushed to swap. A process with multi-GB `VmSwap` is being aggressively paged out — likely the loser in a memory-pressure event.

For the most accurate accounting (including proportional shared swap):

```bash
sudo smem -s swap -r | head -10
```
```
  PID User     Command                         Swap      USS      PSS      RSS
18420 appuser  /usr/bin/java -Xmx20g -jar a   1.2G    21.8G    21.9G    22.8G
 1842 postgres postgres: main process       240.0M     1.8G     1.9G     2.1G
```

### Swap *cached* — a subtle but important field

```bash
grep -E 'Swap|swap' /proc/meminfo
```
```
SwapCached:       420180 kB
SwapTotal:       8388604 kB
SwapFree:         800400 kB
```

`SwapCached` is memory that was swapped out, then read back, but the kernel kept the swap copy "just in case." This is good — it means if the kernel needs to evict that page again, it doesn't have to write to disk. But growing `SwapCached` over time means the system has been actively swapping recently.

### Swappiness

```bash
cat /proc/sys/vm/swappiness
```
The default is usually 60. Lower values (10-30) make the kernel prefer dropping page cache over swapping anonymous memory. Higher values (>60) swap anonymous memory more aggressively. For database hosts, low values are standard:

```bash
sudo sysctl vm.swappiness=10
```

But changing swappiness doesn't fix a memory leak — it just shifts symptoms. Use it as a tuning knob, not a diagnostic.

### Interpreting swap as a signal

- **Swap used but `si`/`so` are zero** → System pushed memory out at some point but isn't currently under pressure. Often a one-time event during a memory spike. Look at `dmesg` for what caused it.
- **Swap used AND active page-in/page-out** → Real ongoing memory pressure. Find the consumer (Step 3, 4) or expand RAM.
- **Swap full and growing OOM kills** → Swap exhausted. Once swap is full, the next allocation that can't be satisfied triggers OOM.
- **No swap configured** → Modern containers often run without swap. OOM kills happen faster (no buffer), but no thrashing is possible. Trade-off.

### Force-flush swap (with caution)

If you've fixed the leak and want to pull everything back from swap (assuming there's RAM for it):

```bash
sudo swapoff -a && sudo swapon -a
```

This moves every page from swap back to RAM, then re-enables swap. Useful after a leak fix, but if there isn't enough RAM, it will OOM the system. Only run this when you're sure there's headroom.

---

## Step 10: Pressure Stall Information (best system-wide signal)

```bash
cat /proc/pressure/memory
```

**Healthy:**
```
some avg10=0.00 avg60=0.00 avg300=0.04 total=18204
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

**Mild pressure (users noticing):**
```
some avg10=8.42 avg60=6.20 avg300=4.18 total=18420180
full avg10=2.10 avg60=1.42 avg300=0.84 total=4201842
```

**Severe (system likely unresponsive):**
```
some avg10=68.42 avg60=58.20 avg300=42.80 total=842018042
full avg10=42.18 avg60=38.40 avg300=28.18 total=420180420
```

`full avg10` above 10% means the entire system stalls regularly on memory. That alone justifies a production incident.

---

## Step 11: Process-specific leak hunting

**JVM:**
```bash
sudo -u appuser jcmd 18420 GC.heap_info
```
```
 garbage-first heap   total 20971520K, used 19842180K
 Metaspace       used 142048K, capacity 142480K
  class space    used 18420K, capacity 18540K
```
Heap is 19.8 GB of 20 GB used. RSS was 22.8 GB — the extra 3 GB is off-heap. With NMT enabled:

```bash
sudo -u appuser jcmd 18420 VM.native_memory summary
```
```
Total: reserved=24820180KB, committed=23420180KB
-                 Java Heap (reserved=20971520KB, committed=20971520KB)
-                    Thread (reserved=842048KB, committed=842048KB)    ← 842 MB threads
-                      Code (reserved=251872KB, committed=120448KB)
-                        GC (reserved=842048KB, committed=842048KB)
```
842 MB in threads — too many threads. Confirm: `ps -L -p 18420 | wc -l`.

**Python:**
```bash
py-spy dump --pid 18420
```

**Native code — eBPF:**
```bash
sudo memleak-bpfcc -p 18420 60
```
```
Attaching to pid 18420, Ctrl+C to quit.
[14:42:18] Top 10 stacks with outstanding allocations:
  142048 bytes in 18204 allocations from stack
    malloc+0x18 [libc.so.6]
    process_request+0x142 [myapp]
    handle_connection+0x84 [myapp]
    main_loop+0x420 [myapp]
```
Exact call path that's leaking.

---

## Step 12: Correlate with what changed

```bash
sudo journalctl --since "24 hours ago" | grep -iE 'oom|killed|memory' | head -20
last reboot | head -5
```
```
reboot   system boot  5.15.0-78-generi Tue May 26 09:18   still running
reboot   system boot  5.15.0-78-generi Mon May 25 03:42 - 09:14 (1+05:32)
reboot   system boot  5.15.0-78-generi Sun May 24 21:18 - 03:41 (06:23)
```
Three reboots in three days is itself a diagnostic.

```bash
# Debian/Ubuntu
grep " install \| upgrade " /var/log/dpkg.log | tail -10
# RHEL/CentOS
rpm -qa --last | head -10
```

Historical sar:
```bash
sar -r -f /var/log/sa/sa25
```
Shows exactly when `%memused` crossed from normal to critical — correlate to deploys, cron jobs, user activity.

---

## Quick triage flow

When the pager goes off, run these four commands first:

```bash
free -h                          # Is memory actually low?
cat /proc/pressure/memory        # Is the system actually stalling?
ps aux --sort=-rss | head -5     # Who's using the most?
sudo dmesg -T | tail -50         # Did the OOM killer fire?
```

Within 60 seconds these tell you: (1) whether the problem is real, (2) user-process or kernel-side, (3) prime suspect, (4) whether kills have already happened.

From there:
- Single process dominates and growing? → Step 4, then Step 11 by runtime
- No single dominator, slab is huge? → Step 7
- Plenty of available memory globally but app OOM-killed? → Step 6 (cgroup)
- `available` looks fine but PSI is bad? → Step 8 (dirty pages / I/O)
- Swap activity sustained? → Step 9
- Everything looks fine *now* but it just rebooted? → Step 5 (dmesg history) + Step 12

The discipline that catches more bugs than any single command: **always sample over time.** One snapshot at 14:00 can't distinguish "process is at steady state" from "process is growing 200 MB/min and will OOM at 14:30." Three samples 60 seconds apart can.

---

## One-liner cheat sheet

Copy-paste-ready commands for fast triage. Replace `$PID` with the process ID under investigation.

### Triage

```bash
# Initial 60-second triage
free -h && cat /proc/pressure/memory && ps aux --sort=-rss | head -5 && sudo dmesg -T | tail -20

# Memory headlines from /proc/meminfo
grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree|Dirty|Slab|SUnreclaim|Committed_AS|CommitLimit|AnonPages|Shmem|HardwareCorrupted):' /proc/meminfo

# Real-time view of memory and swap movement
vmstat 2 10

# Trending over time
sar -r 2 30           # memory utilization
sar -S 2 30           # swap utilization
sar -B 2 30           # paging activity
sar -W 2 30           # swap-in/swap-out rate
```

### Top consumers

```bash
# Top 10 by RSS
ps aux --sort=-rss | head -10

# Top 10 with key fields only
ps -eo pid,user,pri,ni,rss,vsz,pmem,comm --sort=-rss | head -10

# Top by PSS (most accurate accounting)
sudo smem -tk -s pss | head -10

# Top by USS (what you'd actually free by killing)
sudo smem -tk -s uss | head -10

# Per-user totals
sudo smem -u

# Memory per user using ps (no smem needed)
ps -eo user,rss --no-headers | awk '{a[$1]+=$2} END {for (u in a) printf "%-15s %10.2f GB\n", u, a[u]/1024/1024}' | sort -k2 -n -r

# By mapping (libraries / heap / anon)
sudo smem -m -s pss | head -20

# System-wide kernel vs userspace split
sudo smem -w
```

### Inspect a specific process

```bash
# All memory fields for a process
cat /proc/$PID/status | grep -E '^Vm|^Rss'

# Detailed map breakdown
sudo cat /proc/$PID/smaps_rollup

# Address space mapping with sizes
sudo pmap -x $PID | tail -30

# Watch RSS grow over time (the leak test)
while true; do echo "$(date +%H:%M:%S) RSS=$(awk '/VmRSS/{print $2}' /proc/$PID/status) kB"; sleep 60; done

# Quick side-by-side: system + this process
watch -n 2 "free -h; echo; ps -p $PID -o pid,rss,vsz,pmem,comm"

# Open file count (for dentry/inode leaks)
sudo ls /proc/$PID/fd | wc -l
```

### OOM killer

```bash
# All OOM events in dmesg
sudo dmesg -T | grep -iE 'killed process|out of memory|invoked oom'

# OOM events from journal in the last day
sudo journalctl -k --since "24 hours ago" | grep -i oom

# Current OOM scores, top 10 candidates
for pid in $(ps -eo pid --no-headers); do [ -r /proc/$pid/oom_score ] && printf "%6d %4s %s\n" "$pid" "$(cat /proc/$pid/oom_score 2>/dev/null)" "$(cat /proc/$pid/comm 2>/dev/null)"; done | sort -k2 -n -r | head -10

# Full process snapshot from the last OOM event
sudo dmesg -T | grep -A 200 "invoked oom-killer" | tail -200
```

### Cgroups and containers

```bash
# Memory by cgroup, sorted
sudo systemd-cgtop -m --order=memory -n 1

# Cgroup v2 stats for a specific cgroup
cat /sys/fs/cgroup/<path>/memory.current
cat /sys/fs/cgroup/<path>/memory.max
cat /sys/fs/cgroup/<path>/memory.events
cat /sys/fs/cgroup/<path>/memory.pressure
cat /sys/fs/cgroup/<path>/memory.stat

# Find every cgroup with OOM kills
sudo find /sys/fs/cgroup -name memory.events -exec sh -c 'kills=$(awk "/oom_kill/ {print \$2}" "$1"); [ "${kills:-0}" -gt 0 ] && echo "$kills kills: $1"' _ {} \;

# Find cgroups under memory pressure right now
sudo find /sys/fs/cgroup -name memory.pressure -exec sh -c 'p=$(awk "/some/ {print \$2}" "$1"); echo "$p $1"' _ {} \; | sort -r | head -10

# Docker container view
docker stats --no-stream

# Kubernetes pod view
kubectl top pods --all-namespaces --sort-by=memory
```

### Kernel-side

```bash
# Slab usage sorted by cache size
sudo slabtop -o -s c | head -20

# One-shot slab snapshot
sudo cat /proc/slabinfo | sort -k3 -n -r | head -20

# Kernel memory fields
grep -E 'Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|VmallocUsed' /proc/meminfo

# Process with most open files (causes dentry inflation)
sudo lsof 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

# Total open file count
cat /proc/sys/fs/file-nr
```

### Page cache and dirty pages

```bash
# Dirty/writeback right now
grep -E 'Dirty|Writeback' /proc/meminfo

# Find heavy disk writers (correlate with high Dirty)
sudo iotop -oP -d 2

# Diagnostic: how much is actually reclaimable cache? (use carefully)
free -h && sync && echo 3 | sudo tee /proc/sys/vm/drop_caches && free -h
```

### Swap

```bash
# Swap devices and usage
swapon --show

# Active swap movement (look at si/so)
vmstat 2 10

# Per-process swap usage
for f in /proc/*/status; do awk '/^Name:/{name=$2} /^Pid:/{pid=$2} /^VmSwap:/{if ($2+0 > 0) printf "%-25s PID=%-7s Swap=%s kB\n", name, pid, $2}' "$f"; done | sort -k4 -n -r | head -20

# Swap usage via smem (proportional accounting)
sudo smem -s swap -r | head -10

# Current swappiness
cat /proc/sys/vm/swappiness

# Flush swap back to RAM (only when you have headroom!)
sudo swapoff -a && sudo swapon -a
```

### Pressure Stall Information (PSI)

```bash
# System-wide memory pressure
cat /proc/pressure/memory

# CPU and I/O for context
cat /proc/pressure/cpu
cat /proc/pressure/io

# Watch all three together
watch -n 2 'echo "--- memory ---"; cat /proc/pressure/memory; echo "--- io ---"; cat /proc/pressure/io; echo "--- cpu ---"; cat /proc/pressure/cpu'
```

### Process-specific leak hunting

```bash
# JVM heap
sudo -u $USER jcmd $PID GC.heap_info
sudo -u $USER jcmd $PID VM.native_memory summary    # requires -XX:NativeMemoryTracking=summary
sudo -u $USER jmap -histo:live $PID | head -30

# Thread count for a process
ps -L -p $PID | wc -l

# Python
py-spy dump --pid $PID
py-spy top --pid $PID

# Native code (requires bcc-tools)
sudo memleak-bpfcc -p $PID 60
sudo memleak-bpfcc -p $PID -a 60     # show all stacks

# Generic core dump for offline analysis
sudo gcore $PID
```

### History and correlation

```bash
# Recent OOM activity from system log
sudo journalctl --since "24 hours ago" | grep -iE 'oom|killed|memory'

# Boot history
last reboot | head -10

# Package changes
grep " install \| upgrade " /var/log/dpkg.log | tail -20     # Debian/Ubuntu
rpm -qa --last | head -20                                     # RHEL/CentOS

# Historical sar (replace 25 with day of month)
sar -r -f /var/log/sa/sa25
sar -S -f /var/log/sa/sa25
sar -B -f /var/log/sa/sa25
```

### Watch dashboards

```bash
# Live memory + top consumers
watch -n 2 'free -h; echo; ps aux --sort=-rss | head -6'

# Live PSI + free
watch -n 2 'cat /proc/pressure/memory; echo; free -h'

# Live cgroup pressure for all containers
watch -n 2 'for c in /sys/fs/cgroup/docker/*/; do printf "%s " "$(basename $c)"; awk "/some/ {print \$2}" "$c/memory.pressure" 2>/dev/null; done'
```
