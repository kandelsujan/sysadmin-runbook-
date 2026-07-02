# Diagnosing Load Issues with `sar`

Load average is the number everyone glances at first (`uptime`, `top`, monitoring dashboards) and the number most people misread. The reason it's so easy to misdiagnose is baked into its definition: on Linux, "load" doesn't mean "CPU busy-ness." It's a count of processes that are either **runnable and waiting for a CPU**, or **stuck in uninterruptible sleep (D state)**, usually waiting on I/O. Two completely different root causes produce the exact same rising number, and `sar -q` alone can't tell them apart — you have to read it *and* cross-reference it against CPU, disk, memory, and network data to know which one you're actually looking at.

This guide treats load average as a symptom to be triangulated, not a diagnosis by itself.

---

## 1. Setup

```bash
systemctl status sysstat
sar -q -f /var/log/sa/sa15          # replay historical load/run-queue stats
sar -q 1 10                         # live, 1s interval
nproc                               # know your core count before you look at anything else
```

`nproc` (or `lscpu`) first, always — every load number below is meaningless without knowing how many cores you're comparing it against.

---

## 2. The Core Report

`sar` has one report for this: `sar -q`.

```
Time    runq-sz  plist-sz  ldavg-1  ldavg-5  ldavg-15  blocked
14:20   14       520       9.80     7.40     5.10      6
```

| Metric | Meaning |
|---|---|
| `runq-sz` | Processes currently **runnable** — ready to run, waiting only for a free CPU |
| `plist-sz` | Total size of the process list (all processes/threads that exist, running or not) |
| `ldavg-1` | Load average, 1-minute exponentially-decayed window |
| `ldavg-5` | Load average, 5-minute window |
| `ldavg-15` | Load average, 15-minute window |
| `blocked` | Processes in **uninterruptible sleep (D state)** — blocked on I/O, not waiting for CPU |

The load averages (`ldavg-*`) are, roughly, `runq-sz + blocked`, decayed over each time window. That single fact is the key to everything below.

---

## 3. The Central Red Herring: Load ≠ CPU Demand

This is the one thing to internalize before touching anything else. A `ldavg-1` of 12 on an 8-core box *looks* like "12 things want the CPU and I only have 8" — but that's only true if `runq-sz` accounts for most of it. If most of that 12 is coming from the `blocked` column, the machine isn't CPU-starved at all — it has a pile of processes stuck waiting on **disk or network I/O**, and load average is just where that shows up, because Linux counts D-state processes into the load calculation.

**How to disambiguate — always split the number:**

```
ldavg-1 = 12.0, runq-sz = 10, blocked = 1   → genuine CPU contention (10 ≈ most of 12, few blocked)
ldavg-1 = 12.0, runq-sz = 2,  blocked = 9   → I/O contention wearing a "high load" costume
```

Both produce an identical-looking scary `ldavg-1`. Only the split tells you which problem you actually have — and they have entirely different fixes (more/faster cores and better parallelism vs. faster storage/network or fewer concurrent I/O-bound operations).

---

## 4. `runq-sz` — The Smoking Gun for Real CPU Contention

**Smoking gun:** `runq-sz` sustained **above your core count**, with `ldavg-1/5/15` all elevated together (meaning it's not a passing blip — it's persisted long enough to drag the 5 and 15-minute windows up too).

```
8 cores, runq-sz consistently 15-20, ldavg-1 ≈ ldavg-5 ≈ ldavg-15, all ~18
```
This is unambiguous: there is persistently more runnable work than the hardware can execute in parallel. Cross-check with `sar -P ALL` (from the CPU guide) — if it's spread evenly across cores, you need more CPU capacity or better horizontal scaling; if it's concentrated (some cores idle while others are pegged), you have a parallelism/affinity problem that adding cores won't fix on its own.

**Red herring within `runq-sz`:** a short burst — `runq-sz` spikes for one or two samples then drops back to normal, and `ldavg-5`/`ldavg-15` barely move — is usually just a batch job, a cron task, or a deploy script briefly forking a lot of work. The 1-minute average reacting while the 5 and 15-minute averages stay flat is itself the tell that this was transient, not a sustained problem.

---

## 5. `blocked` — The Smoking Gun for I/O-Driven Load

**Smoking gun:** `blocked` count elevated and sustained, `runq-sz` comparatively low, but `ldavg-*` still climbing because `blocked` feeds directly into the load calculation.

```
runq-sz = 3, blocked = 14, ldavg-1 = 15.2 (on an 8-core box)
```
This reads as "the load average is scary but the CPU isn't actually the constraint — 14 processes are stuck waiting on I/O." The next step is **not** more CPU cores; it's finding what they're blocked on:

- Cross-check `sar -d -p` (disk guide) for the same window — elevated `await`/`avgqu-sz` on a device confirms processes are queued behind slow storage.
- Cross-check `sar -n TCP,ETCP` / `sar -n SOCK` (network guide) — processes can also land in D-state waiting on certain network filesystem operations (NFS especially) or synchronous network I/O; check `sar -n NFS,NFSD` if applicable.
- Cross-check `sar -r` (memory guide) — heavy swapping (`pswpin/s`/`pswpout/s` from `sar -W`) also produces D-state processes, since a process waiting for a swapped-out page to come back from disk is, mechanically, blocked on I/O.

**Real example — "the app server is overloaded" ticket that wasn't:**
```
8-core app server, ldavg-1 = 22, runq-sz = 4, blocked = 17
sar -d -p same window: await = 340ms on the data volume (baseline ~4ms)
```
This was reported as a CPU capacity problem and nearly got "fixed" by resizing to a bigger instance. The actual cause: a storage volume had been silently throttled after burst credits ran out (see the disk guide). More CPU would have done nothing — `blocked` and the disk `await` spike together were the real smoking gun, and the fix was on the storage side.

---

## 6. `plist-sz` — Usually Background Noise, Occasionally a Clue

`plist-sz` is the total process/thread count on the system, running or not. It rarely matters on its own, but watch for:

**Red herring:** `plist-sz` slowly growing over weeks in line with normal service scaling (more worker processes deployed, more containers scheduled) — not a problem, just growth.

**Smoking gun (rare but real):** `plist-sz` spiking sharply and rapidly, especially paired with a `proc/s` spike in `sar -w` (CPU guide) at the same timestamp — this is the signature of a fork bomb, a runaway process-spawning bug, or a misconfigured supervisor/orchestrator repeatedly restarting a crashing process. If `plist-sz` explosion precedes a `runq-sz`/`ldavg` climb by a sample or two, you've found the root cause rather than just the symptom.

---

## 7. Reading the Three Windows Together (`ldavg-1` vs `-5` vs `-15`)

The three windows aren't redundant — the *shape* across them tells you about trajectory, which matters as much as the absolute number:

| Pattern | Meaning |
|---|---|
| `ldavg-1` high, `-5` and `-15` still low | Just starting — a spike that hasn't had time to propagate. Could be transient or the early stage of a real problem; watch the next few samples before reacting. |
| `ldavg-1` ≈ `ldavg-5` ≈ `ldavg-15`, all elevated | Sustained, steady-state problem — this has been going on for at least 15 minutes and isn't self-resolving. |
| `ldavg-1` dropping, `-5`/`-15` still high | Recovering — whatever caused it has eased off in the last minute, but the longer windows haven't caught up yet. Don't declare victory until `-5` follows it down. |
| `ldavg-15` climbing steadily over hours across multiple `sar` samples | Slow-building contention — often a leak-shaped problem (memory leak causing swapping, a slow storage degradation, gradually increasing traffic) rather than a sudden event. Look for a trend, not a threshold crossing. |

**Red herring:** reacting to a single elevated `ldavg-1` sample in isolation. Because it's an exponentially-decayed 1-minute average, it's naturally noisy — a brief legitimate burst (a cron job, a deploy, a traffic spike that resolved) will move it without indicating an ongoing issue. Always check whether `-5` and `-15` corroborate before treating it as a real, current problem.

---

## 8. Putting It Together: A Diagnostic Workflow

1. **Get your core count** (`nproc`) before looking at anything else — every threshold below is relative to it.
2. **Establish the time window** for the reported slowness.
3. **Pull `sar -q`** for that window. Split the load number: is it mostly `runq-sz` or mostly `blocked`?
   - Mostly `runq-sz`, exceeding core count, sustained across `-1/-5/-15` → genuine CPU contention → go to `sar -u ALL` and `sar -P ALL` (CPU guide) to check `%iowait`/`%steal` aren't inflating it further, and check per-core balance.
   - Mostly `blocked` → I/O-driven → go to `sar -d -p` (disk guide) for `await`/`avgqu-sz`, `sar -W` (memory guide) for swap activity, and `sar -n` reports (network guide) if network filesystems are in play.
4. **Check the shape across `ldavg-1/5/15`** — transient blip vs. sustained problem vs. slow-building trend changes both urgency and where you look for a root cause (a recent event vs. a gradual leak).
5. **Check `plist-sz` and `sar -w`'s `proc/s`** for a sudden spike that might have *caused* the load rise, rather than just describing it.
6. Only after `sar` has told you *which* resource (CPU, disk, memory, network) is actually behind the load number, move to process-level tools (`ps aux --sort=-%cpu` or `-%mem`, `pidstat`, `iotop`, checking `ps` output for D-state processes specifically with `ps aux | awk '$8 ~ /D/'`) to find the *specific* culprit process.

---

## 9. Quick Reference: Red Herring Checklist

Before declaring a "load" problem, ask:

- Have you split the number into **`runq-sz` vs. `blocked`** — or are you reacting to `ldavg-1` as one undifferentiated blob?
- Is `runq-sz` actually **above your core count**, or does it just look big without a frame of reference?
- Does `blocked` correlate with elevated `await` in `sar -d`, or swap activity in `sar -W` — confirming it's I/O, not CPU?
- Is this a **single noisy `ldavg-1` sample**, or does `-5`/`-15` corroborate that it's sustained?
- Has `plist-sz`/`proc/s` spiked recently — is there a process-creation event that's the actual root cause, with the load rise just downstream of it?
- Are you about to add CPU capacity to fix a number that's actually driven by storage or network I/O?

If you haven't split `runq-sz` from `blocked`, you don't have a load diagnosis — you have a number that could mean "buy more CPU" or "fix your storage" and you won't know which until you look closer.
