# Diagnosing Memory Issues with `sar`

Memory problems are some of the easiest to misdiagnose with `sar` because Linux's memory management is *deliberately* aggressive about using "free" RAM for cache — which means the metrics that look scary to a newcomer (`kbmemfree` near zero, `%memused` near 100%) are often completely normal. The real signal lives one layer deeper, in paging and swapping activity, not in the raw usage numbers.

This guide covers the memory-relevant `sar` reports, what a genuine problem looks like, and how to avoid chasing numbers that are just Linux doing its job correctly.

---

## 1. Setup

```bash
systemctl status sysstat
ls /var/log/sa/
sar -r -f /var/log/sa/sa15          # replay historical memory stats for the 15th
sar -r 1 10                         # live, 1s interval, 10 samples
```

As with network diagnosis, the historical replay against `/var/log/sa/saDD` is what you'll use 90% of the time — someone reports a slowdown after the fact, and you need to see what memory looked like *then*.

---

## 2. The Core Reports

| Flag | What it shows |
|---|---|
| `sar -r` | Memory utilization (free, used, cached, commit) |
| `sar -R` | Memory statistics — page allocation/deallocation rates |
| `sar -B` | Paging (page faults, pages paged in/out) |
| `sar -W` | **Swapping** activity (pages swapped in/out) — the real smoking gun report |
| `sar -S` | Swap space utilization (how full swap is) |
| `sar -q` | Load average + run queue — useful cross-reference |

Run together: `sar -r -B -W 1 5`

---

## 3. `sar -r` — Memory Utilization (mostly a red herring generator)

```
Time    kbmemfree  kbavail   kbmemused  %memused  kbbuffers  kbcached  kbcommit  %commit  kbactive  kbinact  kbdirty
14:20   210348     8391200   16204852   98.70     125440     7890300   14200000  62.40     6200400   9100200  4200
```

**What people do wrong:** they see `%memused` at 98.7% and panic. This is almost always a **red herring on its own**.

- `kbmemfree` (truly unused RAM) being tiny is *expected and healthy* on a long-running Linux box — the kernel uses spare RAM as page cache (`kbcached`) and buffers (`kbbuffers`) to speed up disk I/O, and will instantly release it if an application asks for more memory. Low `kbmemfree` is not a leak; it's efficient use of RAM.
- **The number that matters is `kbavail`** (`MemAvailable` in `/proc/meminfo`) — this is the kernel's own estimate of memory that can actually be given to a new process without swapping, accounting for reclaimable cache. If `kbavail` is healthy relative to total RAM, `%memused` being high is noise.

**Real problem signal:** `kbavail` shrinking over time in lockstep with `kbmemused` climbing, while `kbcached`/`kbbuffers` stay flat or shrink too (meaning the growth isn't cache — it's genuine application memory consumption that the kernel *can't* reclaim). That's a leak pattern.

**`kbcommit` / `%commit`** — this is the sum of memory promised to all processes (including unmapped-but-reserved). If `%commit` climbs past 100% and keeps climbing, the system is over-committing memory it doesn't have — the classic setup for OOM-killer events, especially if `vm.overcommit_memory` is set aggressively. This is worth watching *before* `kbavail` runs out, because it's a leading indicator.

**`kbdirty`** — pages modified in cache but not yet written to disk. A `kbdirty` value that's climbing and staying high (rather than being periodically flushed) suggests the disk I/O subsystem can't keep up with write-back — cross-check with `sar -d` (disk) for the same window. This is a red herring for a "memory" ticket that's actually a storage bottleneck.

---

## 4. `sar -B` — Paging (where real trouble starts to show)

```
Time    pgpgin/s  pgpgout/s  fault/s  majflt/s  pgfree/s  pgscank/s  pgscand/s  pgsteal/s  %vmeff
14:20   12.40     8.20       450.30   0.00      600.10    0.00       0.00       0.00       0.00
```

| Metric | Meaning |
|---|---|
| `pgpgin/s` / `pgpgout/s` | KB paged in/out from disk per second |
| `fault/s` | Total page faults/sec (includes minor faults — normal, cheap) |
| `majflt/s` | **Major** faults/sec — page had to be fetched from disk. This is the one that costs real time |
| `pgscank/s` / `pgscand/s` | Pages scanned by kswapd (background) / directly (in-process, blocking) reclaim |
| `pgsteal/s` | Pages actually reclaimed |
| `%vmeff` | Scan efficiency — `pgsteal / pgscan`, how effective the reclaim scanning was |

**Red herring:** `pgpgin/s`/`pgpgout/s` being nonzero and even fairly high. This happens constantly on any active system just from normal file I/O going through the page cache — it does **not** by itself mean memory pressure.

**Smoking gun #1 — `majflt/s` sustained and elevated.** Minor faults are cheap (just mapping an already-resident page); major faults mean the kernel had to go to disk. A `majflt/s` that's consistently nonzero and correlates with user complaints of "everything feels slow" is real memory pressure manifesting as I/O latency.

**Smoking gun #2 — `pgscand/s` (direct/synchronous scan) nonzero.** This is the important one. `pgscank/s` (kswapd, background reclaim) running is *normal* — the kernel proactively reclaiming cache in the background is healthy housekeeping. But `pgscand/s` > 0 means a process **allocating memory had to stall and do reclaim work itself, synchronously**, because background reclaim couldn't keep up. That's memory pressure directly hurting application latency, not a red herring.

**`%vmeff` dropping low (well under 100%, e.g. 20-30%)** while scan rates are high means the kernel is working hard to reclaim memory and not getting much back for the effort — a sign the system is thrashing near its limits, scanning through pages it can't actually free.

---

## 5. `sar -W` — Swapping (the real smoking gun report)

```
Time    pswpin/s  pswpout/s
14:20   0.00      45.60
```

This is the report to check first when someone says "the box feels sluggish."

- `pswpin/s` — pages swapped **in** from swap space back to RAM (a process needed data that had been swapped out — this is the *expensive* direction, it means something is actively being starved)
- `pswpout/s` — pages swapped **out** to swap space to free up RAM

**Smoking gun:** any sustained nonzero `pswpin/s` or `pswpout/s` on a server workload. Unlike a desktop, a server that's actively swapping is in trouble — swap I/O is orders of magnitude slower than RAM, and once a system starts swapping under load, it commonly spirals (more swap I/O → more disk contention → things get slower → more processes stall waiting on memory → more swapping).

**Red herring to rule out first:** a **one-time small blip** of `pswpout/s` right after boot or right after a large batch job finishes, with nothing sustained afterward. The kernel sometimes proactively swaps out genuinely idle, cold pages (as configured by `vm.swappiness`) to keep more RAM available for cache — a single small swap-out event with no corresponding `pswpin/s` afterward is *not* an application starving for memory, it's routine housekeeping. The real problem is swap **churn** — in and out repeatedly — not the mere existence of any swap activity ever.

**Correlation that confirms it's real:** `pswpin/s` rising at the same timestamps where `sar -q` shows load average spiking and `majflt/s` (from `-B`) also spikes. All three moving together = the system genuinely ran out of usable memory and is thrashing.

---

## 6. `sar -S` — Swap Space Utilization

```
Time    kbswpfree  kbswpused  %swpused  kbswpcad  %swpcad
14:20   4000000    194000     4.60      180000    92.78
```

| Metric | Meaning |
|---|---|
| `%swpused` | Percentage of configured swap space currently occupied |
| `kbswpcad` / `%swpcad` | "Swap cached" — pages that are in *both* swap and RAM simultaneously |

**Red herring:** `%swpused` being nonzero, even moderately (10-20%), with `pswpin/s`/`pswpout/s` from `-W` sitting at zero. This means swap has data sitting in it from *past* memory pressure (or a past process that got swapped out and never got touched again), but nothing is actively moving in or out **right now**. The system is not currently struggling — it's just carrying old swapped-out pages that haven't been reclaimed because nothing has asked for that RAM back yet. Don't alert on this alone.

**Smoking gun:** `%swpused` climbing steadily over hours/days *and* `-W` showing consistent `pswpout/s` during the same climb. That's active, ongoing memory pressure pushing more and more into swap — not idle carryover.

**High `%swpcad`** (like the 92% in the example above) actually indicates something slightly reassuring: most of what's in swap is also still cached in RAM, meaning if that memory is needed back, the kernel doesn't have to do a slow disk read to reclaim it — it can just drop the RAM copy's swap slot. Low `%swpcad` with high `%swpused` means swapped pages have been modified and diverged from RAM (or evicted from RAM entirely), so pulling them back *will* require an actual disk read.

---

## 7. Putting It Together: A Diagnostic Workflow

1. **Establish the time window** of the reported slowness/OOM/crash.
2. **Start with `sar -W`** for that window. Any sustained `pswpin/s`/`pswpout/s`? If yes, you have real memory pressure — proceed. If completely zero throughout, the "memory problem" is very likely something else (CPU, disk I/O, application-level), even if `%memused` looked scary.
3. **Pull `sar -r`** and look at `kbavail` (not `%memused`) trending downward, alongside `kbcommit`/`%commit` climbing — this tells you if it's a slow leak vs. a sudden spike.
4. **Pull `sar -B`** for the same window — check `majflt/s` and specifically `pgscand/s`. Nonzero direct reclaim is your confirmation that allocation requests are stalling on memory pressure in real time.
5. **Cross-correlate with `sar -q`** (load average / run queue) at the same timestamps — swapping-induced slowness shows up as load average climbing even though CPU utilization from `sar -u` might look unremarkable (processes are blocked on I/O, not burning CPU).
6. **Check `dmesg` / `journalctl` for OOM-killer invocations** in the same window — if the kernel actually killed something, that's your confirmed endpoint, and `sar -r`/`-W` in the minutes before it will show the ramp-up.
7. Only after confirming the pattern with `sar`, move to per-process detail (`ps aux --sort=-%mem`, `smem`, or a heap profiler for a leak in a specific application) — `sar` tells you *that* and *when* memory pressure happened system-wide, not *which process* caused it.

---

## 8. Quick Reference: Red Herring Checklist

Before declaring a memory problem, ask:

- Are you looking at **`%memused`/`kbmemused`** (misleading — includes reclaimable cache) or **`kbavail`** (the number that actually matters)?
- Is there **any `pswpin/s`/`pswpout/s` at all** — because without genuine swap I/O, "the system is out of memory" is usually not the correct diagnosis?
- Is `%swpused` **climbing with active swap I/O**, or just a **static leftover** from a past event with no current churn?
- Is `pgscand/s` (direct reclaim, bad) actually elevated, or are you only seeing `pgscank/s` (background reclaim, normal housekeeping)?
- Does the memory metric **correlate** with load average, major faults, and application-level slowness in the *same* time window — or is it an isolated number with nothing else backing it up?
- Could `kbdirty` growth actually be a **disk write-back problem** wearing a "memory" costume?

If you can't point to sustained swap activity or synchronous reclaim (`pgscand/s`) correlating with the reported symptom, you're probably looking at a red herring — Linux is just using RAM the way it's supposed to.
