# Diagnosing Disk I/O Issues with `sar`

Disk diagnosis with `sar` has its own particular trap: the headline metric everyone reaches for — `%util` — is the least trustworthy number in the whole report on modern storage. It was designed for single-spindle disks that could only do one thing at a time; on SSDs, NVMe, and RAID arrays that handle many requests in parallel, `%util` can read 100% while the device is nowhere near actually saturated. The real story is in `await` and queue depth, cross-referenced against throughput.

This guide covers the disk-relevant `sar` reports, what genuine storage contention looks like, and where people get misled.

---

## 1. Setup

```bash
systemctl status sysstat
sar -d -f /var/log/sa/sa15          # replay historical disk stats
sar -d -p 1 10                      # live, 1s interval, -p for readable device names (sda vs dev8-0)
sar -b 1 10                         # system-wide I/O transfer rates
```

`-p` is worth always including — without it, `sar -d` reports devices as `dev8-0` instead of `sda`, which is needless friction when you're trying to match against `lsblk`/`df`.

---

## 2. The Core Reports

| Flag | What it shows |
|---|---|
| `sar -d -p` | Per-device I/O stats — transfers, throughput, queue size, wait time, utilization |
| `sar -b` | System-wide I/O — total transfers/sec and read/write KB/sec across all devices |

That's the full set for block-device I/O — `sar` doesn't break disk down further than per-device, so `-d` does almost all the work here. (Filesystem-level or per-process detail requires `iostat -x`, `pidstat -d`, or `iotop`.)

---

## 3. `sar -d -p` — Per-Device I/O

```
Time    DEV   tps    rd_sec/s   wr_sec/s   avgrq-sz   avgqu-sz   await   svctm   %util
14:20   sda   450.30 200.10     8500.60    38.60      12.40      27.50   1.10    98.90
```

| Metric | Meaning |
|---|---|
| `tps` | Transfers (I/O requests) completed per second — reads and writes combined |
| `rd_sec/s` / `wr_sec/s` | Sectors (512 bytes each) read/written per second |
| `avgrq-sz` | Average size of each request, in sectors |
| `avgqu-sz` | Average number of requests **queued** (waiting + in flight) at the device |
| `await` | Average time (ms) a request spent from submission to completion — **includes queue wait** |
| `svctm` | Average service time — **deprecated/unreliable**, the kernel no longer tracks this accurately on modern drivers. Ignore it. |
| `%util` | Percentage of time the device had at least one request outstanding |

### Red herring: `%util` at or near 100%

This is the single biggest source of false alarms in disk diagnosis. `%util` measures "was the device busy *at all*," not "was the device at capacity." A single-queue-depth spinning disk genuinely can't do two things at once, so 100% `%util` on one meant "fully saturated." But NVMe/SSDs and RAID/multi-disk arrays can service many requests in parallel — a device can show `%util` = 100% while sitting at 20% of its real throughput/IOPS ceiling, simply because *some* request was outstanding at every sampling instant.

**How to tell the difference:** `%util` at 100% is only meaningful **combined with `await`**.
- `%util` = 100%, `await` low and stable (a few ms, matching your storage's known latency, e.g. <1ms for good NVMe, low single-digit ms for SSD, ~5-15ms for spinning disk) → the device is just continuously busy but each request is being serviced promptly. **Not a problem.**
- `%util` = 100%, `await` climbing well past the device's baseline latency → now it's real: requests are actually queueing up and taking longer to complete. **This is the smoking gun**, not the raw `%util` number.

### Smoking gun: `await` sustained and elevated above baseline

`await` is the metric that actually reflects what an application *experiences* — how long it waited for its I/O to come back, including time spent sitting in the queue behind other requests. Establish a baseline for your storage type when things are healthy, then watch for sustained deviation:

```
Healthy NVMe:        await ~0.1-1ms
Healthy SATA SSD:     await ~1-5ms
Healthy spinning disk: await ~5-20ms
Healthy network storage (NFS/SAN): varies widely, establish your own baseline
```

If `await` climbs to 5-10x its normal baseline and stays there across multiple consecutive intervals, applications doing synchronous I/O against that device are genuinely being slowed down by storage — this is real, not a red herring.

**Red herring within `await` itself:** a brief single-sample spike (one 10-minute interval showing elevated `await` surrounded by normal intervals) is often just a burst — a backup job, a big sequential write, log rotation — completing and briefly saturating the queue, then clearing. Only *sustained* elevation across several consecutive samples indicates an ongoing problem worth escalating.

### `avgqu-sz` — the queue-depth cross-check

If `await` is high, `avgqu-sz` tells you *why*: a high average queue size confirms requests are genuinely piling up waiting for the device, rather than each individual request simply being slow for some other reason (e.g., a flaky network-attached storage link introducing per-request latency even with a short queue). Distinguishing "many requests queued behind each other" (a throughput/capacity problem — you need faster or more storage, or fewer concurrent writers) from "queue is short but each request still takes forever" (a latency/connectivity problem — check the storage network path, not the local device config) changes what you fix.

### `avgrq-sz` and workload shape

Watch `avgrq-sz` alongside `tps`. A high `tps` with tiny `avgrq-sz` (lots of small requests) stresses IOPS capacity; a lower `tps` with large `avgrq-sz` (big sequential requests) stresses throughput/bandwidth capacity instead. These have different bottlenecks and different fixes — an all-flash array that's IOPS-rich but bandwidth-limited (or vice versa) will show completely different symptoms depending on which shape of workload is hitting it. Don't assume "high I/O" is one monolithic thing; check whether it's a request-count problem or a bytes-moved problem before tuning.

**Real example — database feels slow, but `%util` is only 45%:**
```
%util = 45%, await = 85ms, avgqu-sz = 18, tps = 120
```
This looks "fine" if you only glance at `%util`. But `await` at 85ms (vs. a normal SSD baseline of a few ms) and a queue depth of 18 tell the real story: something is backed up badly, even though the device isn't "busy" by the crude `%util` measure the whole time window. This is a real, actionable problem — likely too many concurrent writers for the storage's actual IOPS ceiling, or a misconfigured/throttled cloud volume (many cloud block storage products enforce IOPS/throughput limits well below the underlying hardware's real capability — check your provisioned IOPS/burst credits before assuming it's a local hardware issue).

**Real example — the opposite: `%util` = 100%, but everything's actually fine:**
```
%util = 100%, await = 0.3ms, tps = 40000
```
Classic NVMe pattern — the drive always has *something* outstanding because it's busy, but each request completes almost instantly. This is a well-utilized device operating exactly as intended, not a bottleneck. Don't "fix" this.

---

## 4. `sar -b` — System-Wide I/O

```
Time    tps    rtps   wtps   dtps   bread/s   bwrtn/s   bdscd/s
14:20   580.40 120.30 460.10 0.00   4200.50   68000.20   0.00
```

| Metric | Meaning |
|---|---|
| `tps` | Total transfers/sec across all devices |
| `rtps` / `wtps` | Read / write transfers per second |
| `dtps` | Discard transfers per second (TRIM/UNMAP, relevant on SSDs and thin-provisioned volumes) |
| `bread/s` / `bwrtn/s` | Blocks read/written per second, system-wide |

This is a coarse, whole-system overview — useful for a quick "is I/O activity generally elevated right now" gut check, or for correlating a timestamp before drilling into `sar -d -p` to find *which specific device* is responsible. It won't by itself tell you if there's a problem; it just tells you where to point `-d` next if multiple devices are present.

**Red herring:** a high `wtps`/`bwrtn/s` alone, without checking `-d`'s `await`, just means "a lot of writing is happening" — which, as with network throughput, might be completely legitimate (backup, log flush, batch job) rather than a symptom of anything wrong. Volume of I/O and *distress* from I/O are different questions; `sar -b` only answers the first one.

---

## 5. Putting It Together: A Diagnostic Workflow

1. **Establish the time window** for the reported slowness.
2. **Pull `sar -b`** for that window as a quick sanity check — is I/O activity elevated at all compared to normal? If it's flat and unremarkable, disk probably isn't your bottleneck; look at CPU/memory/network instead.
3. **Pull `sar -d -p`** for the same window, per device. Ignore `%util` as a first-pass filter; go straight to `await` and compare against this device's known healthy baseline.
4. **If `await` is elevated**, check `avgqu-sz` to distinguish a throughput/capacity problem (deep queue, many requests genuinely waiting) from a latency/path problem (short queue, but each request itself is slow — check network-attached storage, cloud volume throttling, or a failing physical drive).
5. **Check `avgrq-sz`/`tps` shape** — is this an IOPS-bound workload (many small requests) or a bandwidth-bound one (fewer, larger requests)? That determines whether the fix is "reduce request count / batch writes" or "reduce data volume / compress / provision more bandwidth."
6. **Cross-correlate with `sar -u`** (CPU guide) — a high `%iowait` there, paired with elevated `await` here at the same timestamps, confirms the CPU-idle-but-not-really pattern is caused by *this* device.
7. **Cross-correlate with `sar -r`/`-B`** (memory guide) — heavy `kbdirty` growth followed by a burst of `wtps`/`bwrtn/s` and a matching `await` spike is the write-back-catching-up pattern described in the memory guide; the "disk problem" and "memory problem" tickets are often the same underlying event reported from two different angles.
8. On cloud infrastructure, **check provisioned IOPS/throughput limits and burst-credit balance** for the volume before assuming a hardware or configuration fault — a lot of "mystery" `await` spikes on cloud block storage are simply the volume being throttled back to its provisioned baseline after burst credits ran out.

---

## 6. Quick Reference: Red Herring Checklist

Before declaring a disk problem, ask:

- Are you judging saturation by **`%util`** alone — a metric that means something different on parallel/flash storage than it did on spinning disks?
- Have you checked **`await` against a known healthy baseline** for this specific device type, rather than an arbitrary generic number?
- Is the elevated `await` **sustained across multiple intervals**, or a single-sample blip from a burst job that already finished?
- Is a high `tps`/`bwrtn/s` just **legitimate volume** (backup, batch job) with a normal `await`, rather than actual distress?
- If `await` is high, have you checked `avgqu-sz` to know whether it's a **capacity** problem (add IOPS/throughput) or a **path/latency** problem (check network storage or cloud throttling)?
- On cloud infrastructure — have you ruled out **provisioned IOPS/throughput limits or exhausted burst credits** before assuming a local fault?

If your only evidence is a scary `%util` number, you don't have a disk diagnosis yet — go check `await` first.
