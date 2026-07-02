# Diagnosing Network Issues with `sar`

`sar` (System Activity Reporter, part of `sysstat`) is one of the few tools that can answer "what was happening on this box at 3:14am when things broke" — because it's usually already running in the background, logging to `/var/log/sa/saDD`, every 10 minutes by default.

This guide covers the network-relevant `sar` reports, what healthy vs. broken looks like, and — critically — how to avoid chasing numbers that *look* alarming but aren't the actual problem.

---

## 1. Setup: Make Sure You're Actually Logging

```bash
# Check if sysstat's cron/systemd collection is enabled
systemctl status sysstat        # or: cat /etc/cron.d/sysstat
# Data lives here:
ls /var/log/sa/
# Replay a specific day's binary log:
sar -n DEV -f /var/log/sa/sa15
```

If you don't have historical data, `sar` can still run live:
```bash
sar -n DEV 1 10     # sample every 1s, 10 times
```

The live mode is for confirming a problem *right now*. The historical replay is for figuring out what happened *then*. Most real diagnosis work is the latter — someone reports "the app was slow at 2am" and you go back into the logs.

---

## 2. The Core Reports

| Flag | What it shows |
|---|---|
| `sar -n DEV` | Per-interface throughput (packets/bytes in & out) |
| `sar -n EDEV` | Per-interface **errors** (this is where smoking guns live) |
| `sar -n TCP,ETCP` | TCP connection activity and TCP **errors** |
| `sar -n SOCK` | Socket usage (TCP/UDP/raw sockets in use) |
| `sar -n IP,EIP` | IP-layer stats and IP errors |
| `sar -n ICMP,EICMP` | ICMP traffic and errors |
| `sar -n NFS,NFSD` | NFS client/server stats |

Run several together: `sar -n DEV,EDEV,TCP,ETCP 1 5`

---

## 3. `sar -n DEV` — Throughput (mostly a red herring generator)

```
Time   IFACE   rxpck/s  txpck/s  rxkB/s   txkB/s   rxcmp/s  txcmp/s  rxmcst/s  %ifutil
14:20  eth0    12000.3  11500.1  8500.20  8100.50  0.00     0.00     0.20      68.40
```

**What people do wrong:** they see `%ifutil` climbing toward 80–100% and declare "network saturated!" That's sometimes true, but often a red herring:

- **Red herring case:** `%ifutil` is high but `rxdrop/s` and `txdrop/s` (from `-n EDEV`) are zero. That means the link is busy but *not dropping anything* — throughput is high because the workload legitimately needs it (backup job, bulk transfer). This is not "an issue," it's just load. Don't optimize what isn't broken.
- **Real problem case:** `%ifutil` near 100% **and** `EDEV` shows nonzero `rxdrop/s`/`txdrop/s`, or `TCP` shows retransmits climbing. Now you have saturation *with* consequences — that's your actual bottleneck.

**Smoking gun:** it's never `%ifutil` alone. It's `%ifutil` correlated with drops or retransmits in the same time window.

Also watch `rxpck/s` vs `rxkB/s` ratio — a huge packet count with tiny KB (i.e., average packet size near the ~64-byte floor) suggests something abnormal, like a SYN flood or a broken app sending tiny chatty packets instead of batching. A normal bulk-transfer average packet size is close to the MTU (~1500 bytes for standard Ethernet).

---

## 4. `sar -n EDEV` — Interface Errors (the real smoking guns)

```
Time   IFACE   rxerr/s  txerr/s  coll/s  rxdrop/s  txdrop/s  txcarr/s  rxfram/s  rxfifo/s  txfifo/s
14:20  eth0    0.00     0.00     0.00    45.20     0.00      0.00      0.00      0.00      0.00
```

This is the single most underused report. Most people stop at `DEV` and never look at `EDEV`.

| Metric | Meaning | What it tells you |
|---|---|---|
| `rxerr/s` / `txerr/s` | Physical-layer receive/transmit errors | **Smoking gun** for bad cable, bad SFP/NIC, duplex mismatch |
| `coll/s` | Collisions | Should be **zero** on any modern switched full-duplex network. Nonzero = duplex mismatch or a hub-era problem that shouldn't exist anymore |
| `rxdrop/s` / `txdrop/s` | Packets dropped due to buffer exhaustion | **Smoking gun** for the OS/NIC ring buffer being too small for the traffic burst, or CPU too busy to service interrupts fast enough |
| `txcarr/s` | Carrier errors on transmit | Physical link problem (bad cable, failing port) |
| `rxfram/s` | Frame alignment errors | Physical-layer corruption — cabling, EMI, bad hardware |
| `rxfifo/s` / `txfifo/s` | FIFO overrun errors | NIC/driver couldn't keep up — often correlates with high CPU/softirq load |

**Real example — "the app is randomly slow" ticket:**
```
rxdrop/s consistently 200-500 during business hours, rxerr/s = 0
```
This is *not* a cable/hardware problem (no rxerr). It's a **buffer sizing / CPU servicing problem** — check `ethtool -g eth0` for ring buffer size, and cross-reference with `sar -u` (CPU) or `sar -q` at the same timestamps to see if softirq/ksoftirqd was maxed out (a classic sign that packet processing couldn't keep pace with arrival rate).

**Real example — flaky physical link:**
```
rxerr/s = 15-30, rxfram/s > 0, coll/s = 0
```
This *is* hardware — an SFP going bad, a marginal cable, or a duplex mismatch. `ethtool eth0` for negotiated speed/duplex is the next step, not application tuning.

**Red herring to avoid:** `coll/s` showing up as nonzero on a report pulled from a VM's virtual NIC — some virtual/paravirtualized drivers report bogus values in fields they don't actually use. Cross-check against `ethtool -S` for the same interface before treating it as gospel, especially in cloud/virtualized environments.

---

## 5. `sar -n TCP,ETCP` — Connection & Retransmission Behavior

```
Time   active/s  passive/s  iseg/s   oseg/s
14:20  2.50      45.30      1200.40  980.20

Time   atmptf/s  estres/s  retrans/s  isegerr/s  orsts/s
14:20  0.10      0.05      85.40      0.00       1.20
```

| Metric | Meaning |
|---|---|
| `active/s` | Outbound connections initiated by this host (your app connecting *out*) |
| `passive/s` | Inbound connections accepted (this host as a server) |
| `iseg/s` / `oseg/s` | TCP segments in/out — general traffic volume at the TCP layer |
| `atmptf/s` | Failed **active** connection attempts/sec — this host tried to connect out and failed (RST, timeout) |
| `estres/s` | Established connections reset — **connections that were working, then got RST'd** |
| `retrans/s` | Segments retransmitted/sec — **the #1 smoking gun for network quality problems** |
| `isegerr/s` | Segments received with errors (bad checksum, etc.) |
| `orsts/s` | Outbound resets sent |

**The smoking gun:** `retrans/s` climbing while `oseg/s` stays flat or drops. That ratio (retrans/oseg) is your real signal — it tells you what *fraction* of traffic is retransmission, not just raw count.

```
retrans/s = 5, oseg/s = 5000   → 0.1% retransmit rate → normal, healthy internet-facing traffic
retrans/s = 400, oseg/s = 2000 → 20% retransmit rate  → severe network problem
```

**Real problem example — congested WAN link / packet loss:**
```
retrans/s rising steadily over an hour, atmptf/s also rising, active/s dropping
```
This reads as: connections are failing to even establish (`atmptf/s`), and the ones that do get through are hemorrhaging retransmissions. Classic congested or lossy upstream link, MTU/PMTU black-holing, or a firewall silently dropping packets rather than rejecting them.

**Red herring — high `retrans/s` that isn't a network problem at all:**
An overloaded *application* (e.g., a web server whose accept queue is full, or a backend that's slow to `ACK`) can cause the *client* to retransmit because it never got a timely response — even though the network itself is fine. Distinguish this by checking `estres/s` and correlating with `sar -q` (load average) or `sar -u` on the *server* at the same timestamp. If CPU/load is pegged and retrans is client-side while the server-side interface shows zero errors/drops, the network isn't your bug — your app is.

**Another red herring:** a brief `retrans/s` spike lasting a single 10-minute sample, isolated, with no corresponding drop in `active/s` or rise in `atmptf/s`. This is very likely a transient blip (one lossy packet during a burst) and not indicative of a systemic issue. Look for *sustained* elevation across multiple consecutive intervals before treating it as real.

---

## 6. `sar -n SOCK` — Socket Exhaustion

```
Time   totsck  tcpsck  udpsck  rawsck  ip-frag  tcp-tw
14:20  1450    620     40      0       0        8500
```

| Metric | Meaning |
|---|---|
| `tcpsck` | TCP sockets currently in use |
| `tcp-tw` | Sockets in `TIME_WAIT` |
| `ip-frag` | IP fragments currently queued for reassembly |

**Smoking gun:** `tcp-tw` climbing into the tens of thousands alongside application connection failures ("cannot assign requested address" errors in app logs). This is TIME_WAIT/ephemeral port exhaustion — usually from a high-churn client opening/closing connections rapidly instead of reusing them (e.g., not using keep-alive/connection pooling).

**Red herring:** a high `tcp-tw` number *by itself*, with no corresponding connection errors from the application. Modern kernels handle large TIME_WAIT counts fine; it only becomes a real problem when it starts exhausting the ephemeral port range (check `sysctl net.ipv4.ip_local_port_range`) for a specific source/destination pair (common with NAT'd outbound connections to one heavily-used destination IP:port).

**`ip-frag` nonzero and climbing** is worth attention — it usually means something in the path has a smaller MTU than expected and packets are being fragmented, which is inefficient and sometimes gets silently dropped by firewalls that block fragments. Cross-check with `ping -M do -s <size>` path MTU discovery.

---

## 7. Putting It Together: A Diagnostic Workflow

1. **Establish the time window.** Get the exact timestamp(s) of the reported issue.
2. **Pull `sar -n DEV,EDEV -f /var/log/sa/saDD -s HH:MM:SS -e HH:MM:SS`** for that window.
   - Any errors/drops in `EDEV`? → hardware/buffer lead.
   - High `%ifutil` with no drops? → just load, probably not your bug, look elsewhere.
3. **Pull `sar -n TCP,ETCP`** for the same window.
   - Compute retrans/oseg ratio. Sustained >1-2% is a real signal.
   - Rising `atmptf/s` or `estres/s`? → connections actively failing/dying.
4. **Cross-correlate with `sar -u` (CPU) and `sar -q` (load/run queue)** for the same host, same window — many "network" problems are actually a starved CPU that can't service interrupts or the app fast enough.
5. **Only after that**, escalate to packet capture (`tcpdump`) if you need to see the actual bytes on the wire — `sar` tells you *that* something's wrong and roughly *where*, not the exact packet-level cause.

---

## 8. Quick Reference: Red Herring Checklist

Before declaring a network problem, ask:

- Is the "bad" metric **sustained across multiple intervals**, or a single sample spike?
- Does it **correlate** with an actual symptom (app errors, drops, resets) — or is it just a big number with nothing attached?
- Have you checked the **other side** (CPU/load) before blaming the network?
- On a VM/cloud host — have you sanity-checked against `ethtool -S`, since virtual NIC drivers sometimes misreport certain `EDEV` counters?
- Is the retransmit/error *rate* (relative to traffic volume) actually high, or just the raw count (which naturally rises with more traffic)?

If you can't answer "yes, it correlates with a real symptom," you're probably looking at a red herring.
