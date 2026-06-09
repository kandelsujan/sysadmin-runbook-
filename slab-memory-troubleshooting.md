# Slab Memory Troubleshooting — A Deep-Dive Playbook

**How to diagnose kernel slab memory: tell a benign cache from a real leak, find which cache is growing, attribute it to a workload, and fix it — with real command output, in GB/MB.**

This is the companion to *The Linux Saturation Runbook* and expands Part B §6.3. Reach for it whenever memory is "used" but no process accounts for it, or when `SUnreclaim` is large and climbing. §9 shows what a system **actually looks like** when non-process memory is hurting it, and §10 is a dedicated flow for the classic "`sar -r` shows everything used but `top`/`ps` show nothing" puzzle — which goes well beyond slab.

---

## 1. What slab is, and why it hides from `top`

The **slab allocator** is how the kernel allocates memory for *its own* internal objects — not application memory. Every dentry (directory entry), inode, network socket, connection-tracking entry, and countless generic `kmalloc` buffers lives in slab. None of it is owned by a process, so **it never appears as any process's RSS.** That's exactly why slab growth shows up as "memory used that `top`/`ps` can't explain."

Slab splits into two halves, and **this split is the single most important thing in slab troubleshooting:**

| `/proc/meminfo` field | Meaning | Severity |
|---|---|---|
| **`SReclaimable`** | Caches the kernel can drop under pressure (dentry, inode caches). Counted toward `MemAvailable`. | Usually **benign** — like page cache. |
| **`SUnreclaim`** | Kernel memory actively in use that **cannot** be reclaimed. | The real concern — a large/growing value is a **leak or runaway workload.** |
| **`Slab`** | The sum of the two. | Look at the split, not the total. |

So the first question is never "is slab big?" — it's **"is the big part reclaimable or not?"**

---

## 2. The methodology (five steps)

```
1. SIZE & SPLIT   — how big is Slab, and how much is SReclaimable vs SUnreclaim?   (§3)
2. WHICH CACHE    — which named cache is growing?  (slabtop / slabinfo)            (§4)
3. RECLAIMABLE?   — does it drop under pressure? (drop_caches test)                (§5)
4. TREND          — steady-state working set, or monotonic growth (a leak)?        (§6)
5. ATTRIBUTE+FIX  — map the cache to a workload/subsystem and remediate            (§7,§8)
```

---

## 3. Step 1 — Size and split (in GB)

```bash
awk '/^(Slab|SReclaimable|SUnreclaim|MemAvailable|MemTotal):/ \
  {printf "%-16s %8.2f GB\n", $1, $2/1048576}' /proc/meminfo
```

**HEALTHY / FALSE POSITIVE — big but reclaimable:**
```
MemTotal           125.55 GB
MemAvailable       118.20 GB
Slab                 5.05 GB
SReclaimable         4.75 GB   <- 94% reclaimable (dentry/inode cache)
SUnreclaim           0.30 GB
```
5 GB of slab looks alarming, but it's almost all reclaimable filesystem metadata cache, and `MemAvailable` is huge. The kernel will drop it the instant anything needs RAM. **Not a problem** — at most a tuning opportunity (§8).

**REAL PROBLEM — unreclaimable and large:**
```
MemTotal           125.55 GB
MemAvailable        12.10 GB
Slab                 9.40 GB
SReclaimable         0.40 GB
SUnreclaim           9.00 GB   <- 9 GB you can't get back
```
9 GB pinned in unreclaimable kernel objects, and available memory is shrinking → a **kernel leak or a workload creating unbounded kernel objects.** Go to Step 2.

For containers, the same split lives in the cgroup:
```bash
grep slab /sys/fs/cgroup/memory.stat        # v2
```
```
slab_reclaimable   125829120
slab_unreclaimable 4194304000     <- ~4 GB unreclaimable in this cgroup
```

---

## 4. Step 2 — Which cache is growing?

### 4a. `slabtop` — the top-like view, sorted by cache size

```bash
sudo slabtop -o -s c        # -o = one-shot, -s c = sort by cache size
```
```
 Active / Total Objects (% used)   : 8847362 / 9012345 (98.2%)
 Active / Total Size (% used)      : 4821.34M / 4901.20M (98.4%)

  OBJS    ACTIVE  USE  OBJ SIZE  SLABS OBJ/SLAB  CACHE SIZE  NAME
4200000  4198000  99%   0.19K   200000     21     3200000K  dentry
1100000  1098000  99%   0.58K    78571     14      628568K  inode_cache
 890000   885000  99%   1.00K    55625     16      890000K  ext4_inode_cache
 410000   409500  99%   0.50K    25625     16      205000K  kmalloc-512
```
The **`CACHE SIZE`** column is in KB; divide by 1048576 for GB (3200000K ≈ **3.05 GB** of `dentry` here). The **`NAME`** column is your lead — see the culprit table in §7.

> `slabtop` sort keys: `-s c` cache size, `-s a` active objects, `-s o` total objects, `-s u` utilization. Sort by `c` to find what's eating RAM; sort by `o` to spot caches with millions of objects.

### 4b. `/proc/slabinfo` converted to MB, sorted — scriptable, no interactive tool

```bash
awk 'NR>2 {mb=$3*$4/1048576; if (mb>1) printf "%9.2f MB  %-24s (objs=%d size=%dB)\n", mb, $1, $3, $4}' \
  /proc/slabinfo | sort -rn | head -15
```
```
  3051.76 MB  dentry                   (objs=4200000 size=192B)
   867.19 MB  ext4_inode_cache         (objs=890000 size=1024B)
   612.27 MB  inode_cache              (objs=1100000 size=584B)
   200.20 MB  kmalloc-512              (objs=410000 size=512B)
```
(`/proc/slabinfo` columns: name, active_objs, num_objs, objsize(bytes), … — so `num_objs × objsize` is the memory the cache holds.)

`vmstat -m` gives a similar dump if `slabtop`/`slabinfo` aren't handy.

---

## 5. Step 3 — Is it actually reclaimable? (the drop_caches test)

If Step 1 said it's mostly `SReclaimable`, prove it before concluding "benign." This **diagnostic** asks the kernel to drop reclaimable slab (dentries + inodes):

```bash
# Snapshot, drop reclaimable slab, snapshot again:
grep -E 'SReclaimable|SUnreclaim' /proc/meminfo
sync && echo 2 | sudo tee /proc/sys/vm/drop_caches      # 1=pagecache 2=slab(dentry/inode) 3=both
grep -E 'SReclaimable|SUnreclaim' /proc/meminfo
```
- If `SReclaimable` **drops sharply** → it was genuinely reclaimable cache. **Confirmed benign** (it will refill as the workload touches files — that's normal).
- If `SUnreclaim` **barely moves** (expected — drop_caches can't touch it) and it's still huge → **confirmed leak / in-use**, Step 4.

> **Caveats:** `drop_caches` is a *diagnostic*, not a fix — caches refill immediately, and dropping a hot dentry/inode cache causes a brief latency spike as it rebuilds. Never put it in a cron job as a "memory fix"; that just churns the cache. It does nothing for `SUnreclaim`.

---

## 6. Step 4 — Trend it: working set vs. leak

A big cache at steady state is a working set; a cache that climbs and never falls is a leak. Watch it over time:

```bash
# sample SUnreclaim and the top cache every 10s
watch -n10 "grep -E 'Slab|SReclaimable|SUnreclaim' /proc/meminfo; echo; sudo slabtop -o -s c | head -6"

# or log a single cache over minutes:
for i in $(seq 30); do
  printf "%s  " "$(date +%T)"
  awk '/^SUnreclaim:/{printf "SUnreclaim %.2f GB\n",$2/1048576}' /proc/meminfo
  sleep 10
done
```
```
14:00:01  SUnreclaim 4.10 GB
14:00:11  SUnreclaim 4.42 GB
14:00:21  SUnreclaim 4.78 GB     <- monotonic climb under steady workload = leak signature
```
**Monotonic growth that never plateaus or recovers** is the leak fingerprint. A value that rises with load and falls when load eases is just a working set.

---

## 7. Step 5 — Attribute the cache to a workload

The cache name tells you the subsystem:

| Cache name(s) | What it is | Typical cause | Reclaimable? |
|---|---|---|---|
| `dentry` | directory-entry cache | mass `stat()`/path lookups: `find`, backups, container churn, **negative-dentry buildup** from repeated lookups of nonexistent files | yes |
| `inode_cache`, `ext4_inode_cache`, `xfs_inode` | inode cache | touching huge numbers of files | yes |
| `buffer_head` | block buffer heads | heavy block I/O on many small files | yes |
| `nf_conntrack` | connection tracking | firewall/NAT under a connection flood; tracking table filling | no |
| `TCP`, `sock_inode_cache`, `dst_cache`, `skbuff_*` | socket/network structs | socket leak, tens of thousands of connections, missing `close()` | no |
| `task_struct`, `vm_area_struct`, `signal_cache` | process/thread structs | fork bomb / thread explosion | no |
| `kmalloc-<N>` | generic kernel allocations of size N | hardest to attribute — often a **driver/module leak** | no |
| `radix_tree_node`, `xarray` | page-cache index nodes | enormous page cache | partly |

**The two most common in practice:**

**Negative dentry buildup** — an app that repeatedly `stat()`s paths that don't exist (config probing, library search paths, a poll loop on a missing file) accumulates *negative* dentries. `dentry` cache balloons into the GBs. It's reclaimable so `MemAvailable` stays healthy, but the sheer count is the tell:
```bash
sudo slabtop -o -s o | head -4     # sort by object COUNT
```
```
  OBJS    ACTIVE  USE  OBJ SIZE   CACHE SIZE  NAME
9100000  9098000  99%   0.19K      1750000K   dentry      <- 9.1M dentries
```
Find the offender with `strace`/`opensnoop` on suspect processes:
```bash
sudo opensnoop-bpfcc -x        # -x = only failed opens (the negative lookups)
```

**`nf_conntrack` table filling** — on a router/NAT/firewall box or under a connection flood:
```bash
cat /proc/sys/net/netfilter/nf_conntrack_count        # current entries
cat /proc/sys/net/netfilter/nf_conntrack_max          # the ceiling
dmesg -T | grep -i conntrack                          # "table full, dropping packet"
```
```
$ dmesg -T | grep -i conntrack
[Tue Jun  9 13:58:11 2026] nf_conntrack: nf_conntrack: table full, dropping packet
```

---

## 8. Remediation

**For reclaimable runaway (dentry/inode) — tune reclaim pressure:**
```bash
cat /proc/sys/vm/vfs_cache_pressure          # default 100
sudo sysctl vm.vfs_cache_pressure=200        # >100 = reclaim dentry/inode caches more aggressively
# persist: echo 'vm.vfs_cache_pressure=200' | sudo tee /etc/sysctl.d/99-slab.conf
```
Raising `vfs_cache_pressure` makes the kernel evict the dentry/inode cache sooner — the right knob when a dentry cache grows faster than it's useful. The real fix, though, is to stop the workload generating the lookups (fix the negative-lookup loop, scope the `find`, etc.).

**For `nf_conntrack`:** raise `net.netfilter.nf_conntrack_max` if the box legitimately handles that many flows, shorten timeouts (`nf_conntrack_tcp_timeout_*`), or add a `NOTRACK` rule for traffic that doesn't need tracking.

**For a genuine `SUnreclaim` / `kmalloc-*` kernel leak (doesn't drop, keeps climbing):**
- Note the exact **kernel version** (`uname -r`) and search for known slab-leak fixes — many are specific driver/subsystem bugs fixed in point releases. A kernel upgrade is often the actual fix.
- On a debug kernel with `CONFIG_DEBUG_KMEMLEAK`, scan for leaks:
  ```bash
  echo scan | sudo tee /sys/kernel/debug/kmemleak
  sudo cat /sys/kernel/debug/kmemleak | head -40    # reports unreferenced objects + stack traces
  ```
- Trace which call sites are allocating, to pin the subsystem:
  ```bash
  sudo bpftrace -e 'tracepoint:kmem:kmem_cache_alloc { @[kstack] = count(); }'   # Ctrl-C to print top stacks
  ```
- `drop_caches` will **not** help here — it only touches reclaimable slab.

---

## 9. What it actually looks like when this bites (the symptom picture)

A benign cache is invisible — the system feels fine and `MemAvailable` stays healthy. You only *feel* non-process memory when something **unreclaimable** has eaten the headroom and the kernel can no longer find free pages. The picture then is distinctive, and it's worth recognizing because the usual "find the big process" instinct fails — there is no big process.

**The tells, roughly in the order they appear:**

1. **`kswapd` pegged.** The kernel's reclaim thread runs hot trying to free pages. In `top` you'll see `[kswapd0]` (and per-node `[kswapd1]`, …) near the top burning CPU — often the *only* thing visibly busy.
   ```
   PID USER  %CPU  COMMAND
    89 root  74.2  [kswapd0]      <- reclaim thread thrashing; the app processes below it look idle
   ```

2. **System CPU climbs, throughput drops.** Time goes into `sy` (kernel) for direct reclaim and compaction, not `us`. `vmstat` shows `sy` rising while `us` is unremarkable, and **PSI memory** climbs:
   ```
   $ cat /proc/pressure/memory
   some avg10=64.10 avg60=58.22 avg300=40.07 total=...    <- tasks stalling on memory reclaim
   full avg10=31.50 avg60=28.66 avg300=19.10 total=...
   ```

3. **Swap starts churning with no obvious culprit.** `vmstat -S M 1` shows `si`/`so` moving even though no process in `top` is large — the kernel is pushing *application* anonymous memory to swap to make room for unreclaimable kernel/cache growth.

4. **Allocation failures and odd OOM victims in the log.** This is the smoking gun. The kernel can't satisfy allocations, and the OOM killer fires — often on the **wrong** process, because the real consumer (slab/hugepages/cache) isn't a process the killer can target, so it picks the biggest application instead:
   ```
   $ dmesg -T | grep -iE 'allocation failure|out of memory|killed process|oom'
   [.. ] kworker/3:1: page allocation failure: order:0, mode:0x... 
   [.. ] Out of memory: Killed process 4123 (java) total-vm:... anon-rss:...
   ```
   A `page allocation failure` from a **kernel thread** (`kworker`, a driver), or an OOM kill of a process that *wasn't* the memory hog, both point away from application memory and toward the kernel/non-process side.

5. **`fork`/exec and new allocations fail while a process-level view says there's room.** Apps log `Cannot allocate memory` / `ENOMEM`, `fork: retry: Resource temporarily unavailable`, connection accepts fail — yet summing process RSS shows plenty "free." That contradiction *is* the diagnosis: the missing memory isn't in any process.

6. **In containers, the cgroup OOMs while the host looks fine.** `memory.events` `oom_kill` increments and the container restarts, even though the node has free RAM — the limit was hit by cache/slab inside the cgroup.
   ```
   $ cat /sys/fs/cgroup/memory.events
   oom_kill 7        <- this cgroup has been OOM-killed 7 times
   ```

7. **Subsystem-specific failures** when the eaten memory is a typed cache: `nf_conntrack: table full, dropping packet` (network drops), socket allocation failures, or NFS/filesystem operations stalling.

**The throughline:** high `sy`/reclaim activity, swap or OOM pressure, allocation failures — **with no process that explains it.** When you see that combination, stop hunting processes and start the attribution flow in §10.

---

## 10. The "`sar -r` shows everything used but `top`/`ps` shows nothing" attribution flow

This is the single most common confusing case, and it has a precise cause: **`sar -r %memused` (and classic `free` "used") counts everything that isn't free — including page cache, tmpfs, slab, and other kernel memory that is not owned by any process.** `top` and `ps` only show *process* memory (RSS). So when memory lives outside processes, the two views disagree, exactly as you've seen.

There are only a handful of places non-process memory can hide. Walk them in order.

### 10a. First: is it even real? (the cache false positive)

```bash
free -h
# newer sysstat (12.x) exposes the real headroom column:
sar -r 1 1     # look at kbavail / %memused; if kbavail is large, %memused is just cache
```
If **`available` is large**, then `sar`'s ">95% used" is almost entirely reclaimable **page cache** — a **FALSE POSITIVE**. Nothing is wrong; `sar -r %memused` is doing what it always does (counting cache as used). Confirm and stop.

> Version note: older `sar`/`sysstat` reports `%memused` *including* cache and has no "available" column, which is precisely why it looks alarming. sysstat ≥ 12 added `kbavail`; trust that over `%memused`. If you're on an old version, compute headroom from `/proc/meminfo`'s `MemAvailable` instead.

If `available` is genuinely **low**, the memory is real — find which non-process bucket holds it.

### 10b. The memory ledger — reconcile total against every named consumer (GB)

This one command lays out where the RAM actually went, so the "missing" memory becomes visible:

```bash
awk '
/^MemTotal:/      {t=$2}
/^MemFree:/       {f=$2}
/^MemAvailable:/  {a=$2}
/^Buffers:/       {b=$2}
/^Cached:/        {c=$2}
/^Shmem:/         {sh=$2}
/^SReclaimable:/  {sr=$2}
/^SUnreclaim:/    {su=$2}
/^KernelStack:/   {ks=$2}
/^PageTables:/    {pt=$2}
/^Percpu:/        {pc=$2}
/^VmallocUsed:/   {vm=$2}
/^AnonPages:/     {an=$2}
/^HugePages_Total:/{ht=$2}
/^Hugepagesize:/  {hp=$2}
END {
  G=1048576;
  printf "%-22s %8.2f GB\n","MemTotal",t/G;
  printf "%-22s %8.2f GB\n","MemFree",f/G;
  printf "%-22s %8.2f GB  <- real headroom\n","MemAvailable",a/G;
  print  "---- where used memory lives ----";
  printf "%-22s %8.2f GB  (process anonymous)\n","AnonPages",an/G;
  printf "%-22s %8.2f GB  (page cache, excl tmpfs)\n","PageCache(C-Shmem)",(c-sh)/G;
  printf "%-22s %8.2f GB  (tmpfs / shm — invisible to ps)\n","Shmem",sh/G;
  printf "%-22s %8.2f GB  (kernel slab, reclaimable)\n","SReclaimable",sr/G;
  printf "%-22s %8.2f GB  (kernel slab, UNRECLAIMABLE)\n","SUnreclaim",su/G;
  printf "%-22s %8.2f GB  (kernel thread stacks)\n","KernelStack",ks/G;
  printf "%-22s %8.2f GB  (page tables)\n","PageTables",pt/G;
  printf "%-22s %8.2f GB  (per-cpu data)\n","Percpu",pc/G;
  printf "%-22s %8.2f GB  (driver/vmalloc)\n","VmallocUsed",vm/G;
  printf "%-22s %8.2f GB  (reserved huge pages, not in MemFree)\n","HugePages(reserved)",(ht*hp)/G;
  print  "Note: GPU/DMA driver memory and VM balloon are NOT in meminfo — check §10d.";
}' /proc/meminfo
```
```
MemTotal               125.55 GB
MemFree                  2.10 GB
MemAvailable             6.30 GB  <- real headroom
---- where used memory lives ----
AnonPages               18.40 GB  (process anonymous)
PageCache(C-Shmem)       3.90 GB  (page cache, excl tmpfs)
Shmem                   22.10 GB  (tmpfs / shm — invisible to ps)
SReclaimable             0.80 GB  (kernel slab, reclaimable)
SUnreclaim               8.90 GB  (kernel slab, UNRECLAIMABLE)
KernelStack              0.90 GB  (kernel thread stacks)
PageTables               1.20 GB  (page tables)
Percpu                   0.30 GB  (per-cpu data)
VmallocUsed              0.40 GB  (driver/vmalloc)
HugePages(reserved)     40.00 GB  (reserved huge pages, not in MemFree)
Note: GPU/DMA driver memory and VM balloon are NOT in meminfo — check §10d.
```
Read it like a balance sheet. In the sample above, the "missing" memory is obvious: **40 GB in reserved HugePages + 22 GB in Shmem/tmpfs + 8.9 GB unreclaimable slab** — none of which `top`/`ps` will ever show. `AnonPages` (real process memory) is only 18 GB, which is why summing RSS looked like "nothing."

### 10c. Confirm each suspect bucket

- **Shmem large** → tmpfs / shared memory (§6.5 of the runbook):
  ```bash
  df -h -t tmpfs;  du -sh /dev/shm /tmp /run 2>/dev/null
  ipcs -m            # SysV shared memory segments (databases, etc.)
  ```
- **SUnreclaim large** → kernel slab → run the slab method in §3–§7 above.
- **HugePages reserved** → preallocated and pinned; counted as used but in no process's RSS:
  ```bash
  grep -i huge /proc/meminfo
  cat /proc/sys/vm/nr_hugepages
  ```
  ```
  HugePages_Total:   20480
  HugePages_Free:    20480     <- 20480 * 2048kB = 40 GB reserved AND UNUSED
  Hugepagesize:       2048 kB
  ```
  `HugePages_Free` ≈ `HugePages_Total` means the pages were reserved but nothing is using them — 40 GB stranded. Often a misconfigured DB (Oracle/Java `-XX:+UseLargePages`) or a leftover sysctl. Fix `vm.nr_hugepages`.
- **PageTables / KernelStack large** → too many processes/threads each mapping memory; thousands of threads inflate `KernelStack`, and many processes mapping large regions inflate `PageTables`. The fix is fewer processes/threads, not more RAM.

### 10d. The buckets that aren't in `/proc/meminfo` at all

If the ledger in 10b *still* doesn't add up to "used," the memory is held outside the kernel's normal accounting:

- **ZFS ARC** (very common surprise on ZFS hosts — the ARC cache isn't Linux page cache and historically shows as plain "used"):
  ```bash
  awk '/^size /{printf "ARC size: %.2f GB\n",$3/1073741824}' /proc/spl/kstat/zfs/arcstats 2>/dev/null
  arc_summary 2>/dev/null | grep -i 'ARC size' 
  ```
  A multi-GB ARC explains "all used, nothing in top, not even slab." It's reclaimable but bounded by `zfs_arc_max` — set that if it's crowding the box.
- **VM memory balloon** (the host reclaimed your guest's RAM via a balloon driver — the guest sees it as used by a kernel module, no process):
  ```bash
  lsmod | grep -iE 'balloon'        # virtio_balloon / vmw_balloon / hv_balloon
  dmesg -T | grep -i balloon
  # virtio: /sys/devices/.../virtio*/  ; the ballooned pages show as used with no owner
  ```
  If you're on a VM and memory "disappeared" with no process and no cache, suspect the balloon before anything else.
- **GPU / DMA / device driver memory** (NVIDIA, RDMA, etc.) — pinned by the driver, invisible to `ps`:
  ```bash
  nvidia-smi 2>/dev/null            # GPU memory (separate, but pinned host DMA buffers count against RAM)
  cat /proc/meminfo | grep -i 'DMA\|Bounce'
  ```

### 10e. Attribution flow summary

```
sar -r ~100% used, top/ps show nothing
│
├─ free -h: available LARGE?
│     yes → page cache. FALSE POSITIVE. Done.
│     no  → real; run the ledger (10b)
│
└─ Which bucket dominates the ledger?
      AnonPages   → it IS processes; ps --sort=-rss (you missed it / it's many small ones)
      Shmem       → tmpfs / shm (df -t tmpfs, ipcs -m)
      SUnreclaim  → kernel slab leak → §3–§7
      SReclaimable→ dentry/inode cache (benign; tune vfs_cache_pressure)
      HugePages   → reserved/stranded huge pages (nr_hugepages)
      PageTables / KernelStack → too many procs/threads
      (none add up) → ZFS ARC, VM balloon, or GPU/driver (10d)
```

---

## 11. Slab: problem vs. false positive at a glance

| Signal | FALSE POSITIVE / benign | REAL PROBLEM |
|---|---|---|
| `Slab` total large | mostly `SReclaimable` | mostly `SUnreclaim` |
| `MemAvailable` | still large (slab counted as available) | shrinking alongside slab |
| `drop_caches 2` effect | `SReclaimable` falls sharply | nothing falls; still huge |
| Trend over time | rises with load, falls when idle | monotonic climb, never recovers |
| Dominant cache | `dentry`/`inode_cache` (reclaimable) | `kmalloc-*`, `nf_conntrack`, socket caches |
| `dentry` huge | reclaimable; tune `vfs_cache_pressure` | only "a problem" if reclaim causes latency |
| `nf_conntrack` | below `nf_conntrack_max` | at the ceiling + "table full" in dmesg |

---

## 12. Quick reference — the six commands you'll run most

```bash
# 1. Size & split (GB)
awk '/^(Slab|SReclaimable|SUnreclaim):/{printf "%-14s %.2f GB\n",$1,$2/1048576}' /proc/meminfo

# 2. Which cache (MB, sorted)
awk 'NR>2{mb=$3*$4/1048576; if(mb>1)printf "%8.2f MB  %s\n",mb,$1}' /proc/slabinfo | sort -rn | head

# 3. Reclaimable? (diagnostic)
sync && echo 2 | sudo tee /proc/sys/vm/drop_caches; grep -E 'SReclaimable|SUnreclaim' /proc/meminfo

# 4. Trend (watch the unreclaimable half climb)
watch -n10 "awk '/^SUnreclaim:/{printf \"%.2f GB\n\",\$2/1048576}' /proc/meminfo"

# 5. Object counts (find negative-dentry / object explosions)
sudo slabtop -o -s o | head

# 6. "All used, nothing in top" — where did the RAM go? (GB ledger, §10b)
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}/^Cached:/{c=$2}/^Shmem:/{sh=$2}/^SReclaimable:/{sr=$2}/^SUnreclaim:/{su=$2}/^AnonPages:/{an=$2}/^PageTables:/{pt=$2}/^KernelStack:/{ks=$2}/^HugePages_Total:/{ht=$2}/^Hugepagesize:/{hp=$2}END{G=1048576;printf "avail %.1f | anon %.1f | cache %.1f | shmem %.1f | slabR %.1f | slabU %.1f | pgtbl %.1f | kstack %.1f | huge %.1f  (GB)\n",a/G,an/G,(c-sh)/G,sh/G,sr/G,su/G,pt/G,ks/G,(ht*hp)/G}' /proc/meminfo
```
