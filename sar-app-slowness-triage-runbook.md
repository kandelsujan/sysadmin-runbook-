# "The App Is Running Slow" — A `sar`-Based Triage Runbook

This ties together the CPU, memory, disk, network, and load guides into one ordered troubleshooting sequence. The goal isn't to run every `sar` flag every time — it's to triage fast, ruling resources in or out in an order that avoids chasing red herrings, then drilling into the guide for whichever resource turns out to be guilty.

**Golden rule throughout:** get the exact time window first. "Slow" without a timestamp is un-diagnosable — you'll either look at the wrong interval or end up staring at normal, healthy data. Get the time (or range) from the dev team before running anything.

---

## Step 0: Get the Time Window and Baseline

```bash
# Confirm sar is actually logging historical data
ls -la /var/log/sa/

# Know your hardware before judging any number
nproc
free -h
lsblk
```

Ask the dev team:
- What time (or range) was it slow? Is it still slow right now, or already resolved?
- Slow for everyone, or specific requests/endpoints/users?
- Did anything change recently (deploy, config, traffic pattern, new batch job)?

If it's happening **right now**, you can run `sar` live (`sar -u 1 5`, etc.) instead of replaying logs — faster feedback loop, same reports.

---

## Step 1: One Command, Broad Sweep

Start with a single wide pull across the reported window — this gives you a first-pass read on all five resource areas at once, before deciding where to drill in.

```bash
sar -u ALL -r -B -W -d -p -n DEV,EDEV,TCP,ETCP -q -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
```

(Split into separate commands if the combined output is too dense to read at once — same effect, just multiple calls.)

Scan for the following **first-look red flags**, in this priority order, because each upstream flag can produce symptoms that look like the ones below it — check top-down so you don't misattribute a downstream symptom to the wrong cause:

| Priority | Flag to look for | From report | Points toward |
|---|---|---|---|
| 1 | Sustained `pswpin/s`/`pswpout/s` > 0 | `-W` | Memory pressure — this alone can slow down everything else (CPU stalls on major faults, disk gets hammered by swap I/O, everything looks broken) |
| 2 | `await` far above this device's healthy baseline | `-d -p` | Storage bottleneck — commonly disguises itself as high `%iowait` or a scary load average |
| 3 | `%steal` sustained and nonzero (VM/cloud only) | `-u ALL` | Hypervisor contention — invisible to anything inside the guest except `sar` |
| 4 | `runq-sz` above core count, sustained across `ldavg-1/5/15` | `-q` | Genuine CPU contention |
| 5 | `retrans/s` elevated relative to `oseg/s`, or `rxdrop/s`/`txdrop/s` nonzero | `-n TCP,ETCP` / `-n EDEV` | Network packet loss/saturation |

**Why this order:** memory pressure and storage bottlenecks are upstream causes that manifest as CPU and load symptoms further down the list. Checking swap and disk `await` first prevents you from spending an hour tuning CPU/threading settings for a problem that's actually a maxed-out storage volume or a memory leak. Chase the highest-priority flag that's actually present first.

---

## Step 2: Follow Whichever Flag Fired

### If memory (swap activity) fired → go deep on memory
```bash
sar -r -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sar -W -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sar -B -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
```
Check `kbavail` trend (not `%memused`), `%commit`, `pgscand/s`. See the **memory guide** for full detail. Likely culprits: an application leak, an oversized cache/heap setting relative to available RAM, or too many co-located processes for the box's memory.

### If disk (`await`) fired → go deep on disk
```bash
sar -d -p -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sar -b -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
```
Check `avgqu-sz` to tell capacity vs. path/latency problem. On cloud infra, check provisioned IOPS/burst credits before assuming a hardware fault. See the **disk guide**.

### If `%steal` fired → escalate off-host
Nothing to tune locally. Confirm sustained (not a blip), then check with your cloud provider/hypervisor team about host contention, or consider a differently-sized/dedicated instance. See the **CPU guide**, Section 3.

### If CPU (`runq-sz`) fired → go deep on CPU
```bash
sar -u ALL -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sar -P ALL -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
sar -w -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
```
Check per-core balance (one hot core vs. evenly spread), and `%system` vs `%user` ratio. See the **CPU guide**.

### If network fired → go deep on network
```bash
sar -n DEV,EDEV,TCP,ETCP,SOCK -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS
```
Check retransmit *rate* (not raw count), and whether errors are on your host's interface or the pattern suggests something upstream. See the **network guide**.

### If nothing in Step 1 fired at all
This is a useful, real outcome — it tells you the slowness is very likely **not infrastructure-level**, and `sar` has done its job by ruling out the whole machine. Move to:
- Application-level profiling (APM tool, `strace -c` on the process, language-specific profiler)
- Database query performance (slow query log, `EXPLAIN` on suspect queries)
- Downstream dependency latency (a third-party API, a microservice the app calls, DNS resolution time)
- Lock contention or thread pool exhaustion inside the application itself

`sar` diagnoses the *host*. If the host is clean across CPU/memory/disk/network/load, the bottleneck is inside the application or something it talks to.

---

## Step 3: Confirm With a Second, Independent Signal

Before reporting a root cause back to the dev team, corroborate the `sar` finding with something outside `sar` — this avoids acting on a coincidental correlation:

| Suspected cause | Corroborate with |
|---|---|
| Memory leak / swap | `dmesg`/`journalctl` for OOM-killer events; `ps aux --sort=-%mem` for the specific process; app-level heap metrics if available |
| Disk bottleneck | `iostat -x` for a second opinion on the same device; check cloud console for volume throttling/burst-credit graphs |
| CPU contention | `top`/`htop` live, or `pidstat -p <pid> 1` for the specific process; `perf top` if you need call-stack detail |
| Network loss | `ping`/`mtr` to the relevant destination for current-state confirmation; `tcpdump` if you need packet-level detail |
| `%steal` | Cloud provider's own host-level metrics dashboard, if available |

If the independent signal agrees, you have a confirmed root cause. If it doesn't, go back to Step 1 — you likely picked up a red herring from one of the guides' warning sections (a transient blip, a metric that means something different than it looks like it means, or a symptom correlated with but not caused by the resource you checked).

---

## Step 4: Report Back

For the dev team, a useful report includes:
- **The time window** you analyzed
- **Which resource** was implicated, with the specific `sar` metric and value (not just "CPU was high" — "`runq-sz` was 24 on an 8-core box for a sustained 20 minutes, all cores evenly loaded")
- **The corroborating signal** from Step 3
- **Whether it's ongoing, resolved, or recurring** — check if the same pattern shows up at the same time on other days (cron job, batch window, daily traffic peak) before treating it as a one-off incident

---

## One-Page Cheat Sheet

```
1. Get the exact time window. No timestamp = no diagnosis.
2. sar -u ALL -r -B -W -d -p -n DEV,EDEV,TCP,ETCP -q  (one wide sweep, that window)
3. Check in this order, stop at the first real hit:
   a. pswpin/s or pswpout/s > 0, sustained     → MEMORY  (see memory guide)
   b. await >> device baseline                 → DISK    (see disk guide)
   c. %steal sustained (cloud/VM)               → NOISY NEIGHBOR (escalate to provider)
   d. runq-sz > core count, sustained           → CPU     (see cpu guide)
   e. retrans/s high relative to oseg/s,
      or rxdrop/s/txdrop/s nonzero              → NETWORK (see network guide)
4. Nothing hits?  → It's the application, not the host. Profile the app/DB/dependencies.
5. Corroborate with a non-sar signal before reporting root cause.
6. Report: time window + specific metric/value + corroboration + one-off vs. recurring.
```
