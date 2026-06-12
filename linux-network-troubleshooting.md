# Linux Server Network Troubleshooting — A Comprehensive Field Guide

When a Linux server "can't reach" something, or something "can't reach it," or things are just *slow*, the cause can sit at any layer from the cable to the application. This guide gives you a **systematic method**, a **toolkit**, and **detailed playbooks** for the common (and a few nasty uncommon) network problems you'll hit on Linux servers — with the commands to run and how to read what they tell you.

It's a companion to the traffic-investigation guide: that one is about *whether traffic should be happening*; this one is about *why traffic isn't working the way it should.*

---

## Part 0 — How to approach any network problem

### 0.1 The layer ladder

Networking is layered, and so is troubleshooting. Almost every problem lives at one of these rungs. Pick a direction and walk it — don't jump around randomly.

| Rung | Question | Tools |
|---|---|---|
| **L1/L2 — Link** | Is the interface up? Is the cable/NIC healthy? Right speed/duplex? | `ip link`, `ethtool`, `ip -s link` |
| **L3 — IP & routing** | Does the host have the right IP? Is there a route? Is the gateway reachable? | `ip addr`, `ip route`, `ip neigh`, `ping` |
| **DNS — Name resolution** | Does the name resolve, correctly and quickly? | `dig`, `getent`, `resolvectl` |
| **L4 — Reachability** | Can I open a connection to the port? Is the service listening? Firewall? | `ss`, `nc`, `curl`, `iptables`/`nft` |
| **L7 — Application** | Does the service actually respond correctly (HTTP/TLS/etc.)? | `curl -v`, `openssl s_client`, app logs |

**Bottom-up** (link → app) is best when something is totally broken. **Top-down** (app → link) is best when *most* things work but one thing fails. Either way, finish each rung before climbing.

### 0.2 The golden rules

1. **Reproduce it minimally.** Don't debug through the whole application — reach for `curl`, `nc`, or `ping` to isolate the network from the app.
2. **Change one thing at a time**, and re-test after each change.
3. **Compare against a known-good host** on the same subnet. If a sibling server works and this one doesn't, the problem is *this host*, not the network.
4. **Localize the failure.** Test from several vantage points: from the server outward, from a peer to the server, and from the far end back. Where it breaks tells you where to look.
5. **Name the symptom precisely.** "Can't connect" is not one thing — *refused*, *timed out*, *reset*, and *no route* each point at a different cause (see Part 5.1). Getting the exact error is half the diagnosis.
6. **When in doubt, capture.** `tcpdump` is ground truth — it shows you what actually left and arrived, which beats every assumption.
7. **Rule DNS in or out early.** A surprising share of "network" problems are name-resolution problems wearing a disguise.

### 0.3 The 60-second triage

A fast first pass before you go deep:

```
ip -br addr            # do I have an IP, is the interface UP?
ip route               # do I have a default route?
ping -c2 <gateway>     # is my own gateway reachable? (L1-L3 to the first hop)
getent hosts <name>    # does the name resolve the way the app would see it?
ping -c2 <dest-ip>     # is the destination reachable by IP? (ICMP may be blocked - see note)
nc -vz <dest> <port>   # can I open the actual service port?
```
Where this sequence first fails tells you which Part to jump to.

---

## Part 1 — The diagnostic toolkit

| Tool | Use it for |
|---|---|
| `ip` (addr/link/route/neigh) | The modern everything-tool for L2/L3 config and state |
| `ethtool` | NIC link state, speed/duplex, driver stats, ring buffers, offloads |
| `ss` | Sockets: what's listening, connection states, per-socket TCP internals |
| `ping` | Basic reachability + round-trip time (ICMP) |
| `traceroute` / `tracepath` / `mtr` | Path discovery, per-hop loss/latency, path MTU |
| `dig` / `host` / `getent` / `resolvectl` | DNS resolution (and the resolver *stack*) |
| `nc` (netcat) / `curl` / `openssl s_client` | Test a specific port / HTTP / TLS without the app |
| `tcpdump` | Capture packets — the ground truth |
| `iptables` / `nft` / `firewall-cmd` / `conntrack` | Inspect the local firewall and connection tracking |
| `nstat` / `netstat -s` / `/proc/net/*` | Kernel protocol counters (drops, retransmits, overflows) |
| `iperf3` | Measure throughput/loss/jitter between two hosts |
| `dmesg` / `journalctl -k` | Kernel messages: link flaps, NIC resets, conntrack-full, drops |
| `arping` | L2 reachability and duplicate-IP detection |

Install notes: `ip`, `ss`, `ping`, `dmesg` are always present. `ethtool`, `tcpdump`, `dig` (dnsutils/bind-utils), `mtr`, `nc`, `iperf3`, `conntrack`, `arping` may need installing. `tcpdump`, `ethtool` register/stats, and packet captures need root.

---

## Part 2 — Layer 1 / 2: link and interface problems

**Symptoms:** total loss of connectivity on a host or interface; intermittent drops; terrible throughput with no obvious cause; rising error counters.

### 2.1 Is the interface up and does it have carrier?

```
ip -br link
```
```
lo               UNKNOWN   00:00:00:00:00:00
eth0             UP        52:54:00:a1:b2:c3
eth1             DOWN      52:54:00:a1:b2:c4
```
- **UP** = administratively up *and* has carrier (a live link). **DOWN** = no link.
- A `NO-CARRIER` flag in `ip link show eth0` means the interface is enabled but the physical link is dead (unplugged cable, dead switch port, or — on VMs — a detached virtual NIC).

Bring an interface up: `ip link set eth0 up`. If it won't come up, the problem is below the OS (cable/switch/NIC/driver).

### 2.2 Speed and duplex — the silent performance killer

```
ethtool eth0
```
```
        Speed: 1000Mb/s
        Duplex: Full
        Auto-negotiation: on
        Link detected: yes
```
- **`Link detected: no`** → physical link problem (Part 2.1).
- **`Duplex: Half`** on a modern link, or a **speed far below** what the port supports (e.g. `100Mb/s` on a gigabit NIC) → a **duplex/speed mismatch**, almost always caused by one side being *hard-set* and the other *auto-negotiating*. The classic signature is "it works but it's horribly slow and lossy," with **late collisions** and **FCS/CRC errors** climbing (next section). Fix: set both sides to auto-negotiate, or hard-set both identically.

### 2.3 Interface error counters

```
ip -s link show eth0
```
```
    RX:  bytes packets errors dropped  missed   mcast
   9.9G    8.1M      0   1024       0    2048
    TX:  bytes packets errors dropped carrier collsns
   4.2G    5.0M      0       0       3       0
```
What the columns mean and point to:

- **RX errors / TX errors** — malformed frames. Rising RX errors → cabling, SFP, or duplex mismatch (look for CRC/FCS in `ethtool -S`).
- **RX dropped** — frames the kernel discarded after receiving them: often **ring buffer overruns** (NIC faster than the CPU/kernel could drain), or no matching socket. Under load → suspect ring buffers / IRQ / CPU.
- **RX missed / overrun (fifo)** — the NIC's hardware buffer filled before the host drained it. Tune ring buffers / interrupt handling.
- **TX carrier** — link went down/up while sending → a **flapping link** (bad cable/SFP/port).
- **collsns (collisions)** — should be 0 on full-duplex. Nonzero → half-duplex somewhere (duplex mismatch).

Driver-level detail (names vary by NIC):
```
ethtool -S eth0 | grep -iE 'err|drop|crc|fifo|miss|over|no_buf'
```
- `rx_crc_errors` / `rx_fcs_errors` → physical/cabling/duplex.
- `rx_dropped` / `rx_no_buffer_count` / `rx_fifo_errors` → buffer/CPU can't keep up.
- `rx_missed_errors` → ring buffer too small for the load.

### 2.4 Ring buffers and offloads

If you see RX drops under heavy traffic, check and enlarge the ring buffer:
```
ethtool -g eth0          # show current vs max ring sizes
ethtool -G eth0 rx 4096  # raise RX ring (up to the max shown above)
```
Offloads (GRO/GSO/TSO/LRO) are normally fine, but two gotchas:
- **Captures look wrong** — `tcpdump` may show frames *larger than the MTU* because GRO has already merged them. To capture true on-the-wire sizes: `ethtool -K eth0 gro off lro off` (remember to turn back on).
- Rarely, a buggy offload causes corruption/throughput issues; disabling it is a valid test.

### 2.5 Kernel log for hardware/link events

```
dmesg -T | grep -iE 'eth0|link|nic|carrier|reset|firmware'
```
Look for link up/down flapping, NIC resets/hangs, or driver firmware errors — these explain intermittent outages that the counters only hint at.

---

## Part 3 — Layer 3: IP address, routing, and ARP

### 3.1 IP address problems

```
ip -br addr show eth0
```
- **No address** → DHCP failed or static config didn't apply. Check your network config (netplan, NetworkManager, `/etc/network/interfaces`, ifcfg) and `journalctl -u NetworkManager` / `systemd-networkd`.
- **Wrong subnet mask** → host thinks remote machines are local (or vice-versa) and routes them wrong. A `/24` host with a `/16` neighbour will fail to reach hosts it should reach directly.
- **Duplicate IP** → the nastiest: *intermittent* connectivity that changes with ARP timing. Detect it:
  ```
  arping -D -I eth0 -c 3 10.0.12.5     # -D = duplicate-address detection
  ```
  A reply means **another host already owns that IP.** Also check `dmesg` for "duplicate address detected" and watch `ip neigh` — a MAC that keeps changing for one IP is the tell.

### 3.2 Routing problems

```
ip route
```
```
default via 10.0.12.1 dev eth0
10.0.12.0/24 dev eth0 proto kernel scope link src 10.0.12.5
```
- **No `default via …` line** → you can reach your local subnet but nothing beyond it. "Network is unreachable" for anything off-LAN.
- **Wrong gateway** → off-subnet traffic goes to a dead/wrong next hop → timeouts to everything remote while local works.
- **Multiple default routes** with different metrics → traffic may take an unexpected exit; check `ip route` for two `default` lines and their `metric` values.

Ask the kernel exactly how it will reach a destination (no probing):
```
ip route get 10.0.30.20
```
```
10.0.30.20 via 10.0.12.1 dev eth0 src 10.0.12.5
```
This tells you the **interface, gateway, and source IP** that will be used. If it picks a surprising interface or source, you've found a routing/policy issue. `ip rule` shows policy-routing rules if multiple tables are in play.

### 3.3 ARP / neighbour problems (the local-segment layer)

For hosts on the *same* subnet, IP must be resolved to a MAC via ARP. Broken ARP = can't talk to a host that's "right there."

```
ip neigh show
```
```
10.0.12.1 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE
10.0.12.50 dev eth0  INCOMPLETE
```
- **REACHABLE / STALE** — normal (STALE just means "not used recently," not broken).
- **INCOMPLETE / FAILED** — ARP got no answer: the target is **down, on a different VLAN, or unreachable at L2.** This is a layer-2 problem, not routing.

Test L2 reachability to the gateway directly:
```
arping -I eth0 -c 3 10.0.12.1
```
No replies → you can't even reach your gateway at layer 2 → suspect the switch port, VLAN assignment, or cabling.

### 3.4 Reverse-path filtering (a sneaky asymmetric-routing trap)

If a host has multiple interfaces or asymmetric paths, the kernel may **silently drop** packets whose reply route doesn't match the arrival interface:
```
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth0.rp_filter
```
`1` = strict reverse-path filtering. On a multi-homed/asymmetric box this drops legitimate traffic with no log by default. Setting it to `2` (loose) or `0` is the fix/test — but understand *why* the path is asymmetric first.

---

## Part 4 — DNS resolution problems

DNS deserves its own part because it's both extremely common and full of traps. The golden move is to separate **"does DNS answer?"** from **"does the *resolver stack the app uses* answer?"** — they're not the same.

### 4.1 The single most useful DNS distinction: `dig` vs `getent`

- **`dig` talks straight to a DNS server.** It ignores `/etc/hosts`, `nsswitch.conf`, mDNS, and systemd-resolved.
- **`getent hosts <name>` uses the *same path your applications use*** — the NSS stack: `/etc/hosts`, then DNS, plus whatever `nsswitch.conf` says.

```
dig +short app.db.example.internal      # what pure DNS returns
getent hosts app.db.example.internal    # what your apps actually get
```
**If `dig` works but `getent` (and your app) doesn't**, DNS itself is fine — the problem is in the resolver stack: `/etc/hosts`, `/etc/nsswitch.conf`, or systemd-resolved. That one comparison saves hours.

### 4.2 Where resolution is configured

```
cat /etc/resolv.conf                    # nameservers + search domains
grep ^hosts /etc/nsswitch.conf          # order: files dns ...  (files = /etc/hosts)
resolvectl status                       # systemd-resolved: per-link servers, DNSSEC
```
- On systemd-resolved systems, `/etc/resolv.conf` often points at `127.0.0.53` (the stub resolver); the *real* servers are shown by `resolvectl status`. Edit the wrong place and your change does nothing.
- A stale or wrong entry in `/etc/hosts` overrides DNS for that name — check it when one specific name resolves "wrong."

### 4.3 Reading DNS failures

Run a verbose query:
```
dig app.example.internal
```
- **`status: NOERROR`** with an answer → resolution works.
- **`status: NXDOMAIN`** → the name genuinely doesn't exist (typo, wrong domain, or missing record).
- **`status: SERVFAIL`** → the server tried and failed (broken upstream, DNSSEC validation failure, or a sick resolver).
- **`;; connection timed out; no servers could be reached`** → you can't reach the DNS server at all (firewall on 53, wrong server IP, server down). This is a *connectivity* problem to the resolver, not a DNS-data problem.

Target a specific server to localize:
```
dig @10.0.0.53 app.example.internal     # ask one resolver directly
dig +trace app.example.internal         # walk the delegation from the root down
dig +tcp app.example.internal           # retry over TCP (large answers / UDP blocked)
```

### 4.4 Slow resolution and the `ndots` / search-domain trap

If name lookups are *slow* (and everything feels laggy because each connection waits on DNS):
- **Long `search` list** in `resolv.conf` → every short name is tried against each suffix in turn, multiplying queries.
- **`options ndots:5`** (common in Kubernetes) → names with fewer than 5 dots get the search suffixes appended *first*, causing several failed lookups before the real one. A fully-qualified name with a trailing dot (`name.example.internal.`) skips this.
- A **dead primary nameserver** → every lookup waits for the timeout before falling to the secondary. `dig` against each listed server finds the dead one.

---

## Part 5 — Layer 4: reachability, ports, and the firewall

### 5.1 Name the failure: refused vs timeout vs reset vs no route

This table is the most valuable thing in the guide. The *exact* failure mode points straight at the cause.

| Symptom (from `curl`/`nc`/app) | What actually happened | Most likely cause |
|---|---|---|
| **Connection refused** | Host replied with TCP **RST** | You reached the host, but **nothing is listening** on that port (service down / bound elsewhere), or a firewall **REJECT** rule |
| **Connection timed out** | **No reply at all** | Packet **silently dropped**: firewall **DROP**, host down, wrong route, or a network blackhole |
| **No route to host** / **Network is unreachable** | Local stack has **no path**, or a router returned ICMP unreachable / ARP failed | Missing/wrong route, gateway down, or L2/ARP failure on the local segment |
| **Connection reset by peer** | Connection established, then **RST mid-stream** | Service crashed/closed abruptly, app rejected the request, or a middlebox killed an idle/over-limit connection |
| **Connects but hangs** (no data, or stalls on big transfers) | Handshake OK, data doesn't flow | Often **MTU/PMTUD blackhole** (Part 6.4); also app-level deadlock |

Get the precise symptom cheaply:
```
nc -vz 10.0.30.20 5432          # TCP: prints "succeeded" / "refused" / hangs (=timeout)
nc -vzu 10.0.30.20 53           # UDP test
curl -v --connect-timeout 5 http://10.0.30.20:8080/
# no nc? pure-bash TCP test:
timeout 3 bash -c '</dev/tcp/10.0.30.20/5432' && echo open || echo "closed/filtered"
```

### 5.2 Is the service even listening (on the right address)?

On the **destination** host:
```
ss -tlnp
```
```
State   Recv-Q  Send-Q  Local Address:Port   Process
LISTEN  0       4096    127.0.0.1:5432       users:(("postgres",pid=900))
LISTEN  0       511     0.0.0.0:443          users:(("nginx",pid=990))
```
- **Bound to `127.0.0.1`** (like postgres above) → it only accepts *local* connections; remote clients get **connection refused**. Classic "works from the box, not from anywhere else." Fix is in the service config (`listen_addresses`, `bind`, etc.).
- **`0.0.0.0:443`** → listening on all interfaces, reachable remotely (firewall permitting).
- **Not listed at all** → the service isn't running or failed to bind. Check `systemctl status` and its logs.
- **Recv-Q on a LISTEN socket** = connections waiting to be accepted (current backlog). **Send-Q** = the configured backlog limit. Recv-Q pinned at the Send-Q value means the app isn't accepting fast enough → **backlog drops** (Part 7.3).

### 5.3 The local firewall

If the service listens but you still can't reach it, suspect the firewall — local or in-path.

```
iptables -L -n -v --line-numbers        # legacy view, with packet counters
nft list ruleset                          # nftables (modern default on many distros)
firewall-cmd --list-all                   # firewalld front-end
```
- **Watch the counters.** Run the failing connection, then re-list: a **DROP/REJECT rule whose packet count increased** is the one biting you.
- **DROP vs REJECT matters** and matches Part 5.1: `DROP` → client sees **timeout**; `REJECT` → client sees **refused** (or a specific ICMP unreachable).
- Check the right chain/direction: inbound problems are in `INPUT`, outbound in `OUTPUT`, and traffic *through* the box in `FORWARD`.
- Don't forget the **far end and the network**: a host-based firewall on the destination, a cloud **security group/NACL**, or an in-path firewall can all DROP silently. If the destination's own `ss`/firewall look fine, capture on the destination (Part 5.4) to see whether your packets even arrive.

### 5.4 Capture to settle it

When the logic runs out, watch the packets. Run on the **destination** while you connect from the source:
```
tcpdump -nni eth0 host 10.0.12.5 and port 5432
```
- **You see the SYN arrive, host replies SYN-ACK** → network is fine; the problem is the app/client.
- **SYN arrives, host replies RST** → reached the host, port closed/REJECTed → "refused."
- **SYN arrives, no reply** → a firewall on the destination is DROPping after arrival.
- **SYN never arrives** → it's being dropped *in the path* (in-path firewall, routing, security group). Capture hop-by-hop / from both ends to find where it dies.

This SYN-followed-by-what test localizes almost any reachability problem to host-vs-network in one move.

---

## Part 6 — Performance: latency, loss, throughput, MTU

"It works but it's slow" problems. Establish *which* of latency, loss, or throughput is actually wrong before tuning.

### 6.1 Latency (round-trip time)

```
ping -c 20 10.0.30.20
```
Read the summary: `min/avg/max/mdev`. High **avg** = a slow path. High **mdev** (jitter) = inconsistent path / congestion / a struggling hop. A few caveats:
- Routers often **deprioritize or rate-limit ICMP**, so ping latency/loss to an intermediate device can look bad while real traffic is fine. Trust the **end-to-end** number, and prefer a TCP-based test to the *actual service port* for the truth.
- Use `mtr` to see where latency builds up (Part 6.3).

### 6.2 Packet loss

```
mtr -n -c 100 --report 10.0.30.20
```
Read it carefully — **loss at a middle hop that does NOT persist to the final hop is usually cosmetic** (that router just rate-limits ICMP to itself). **Real loss shows up at the destination and at every hop after the point where it starts.** Also confirm loss with a TCP/real-traffic test, since ICMP isn't representative.

Confirm TCP-level loss via retransmissions:
```
nstat -az | grep -iE 'TcpRetransSegs|TcpExtTCPLostRetransmit|TcpInErrs'
ss -ti dst 10.0.30.20            # per-connection: look for 'retrans:' and 'rtt:'
```
Rising retransmits = real loss/congestion on the path.

### 6.3 Localizing latency/loss along the path

```
mtr -n 10.0.30.20
```
Each line is a hop with its own latency and loss. The hop where latency **jumps and stays high**, or where loss **starts and continues to the end**, is your suspect segment. Combine with `ip route get` (Part 3.2) to know which of your own paths/interfaces is in play.

### 6.4 MTU and PMTUD blackholes — the "connects then hangs" classic

**Signature:** small operations work perfectly (SSH *connects*, the TLS handshake completes, `ping` is fine) but anything that sends **large packets hangs or stalls** — a big `scp`, a bulk HTTP download, a database result set. This is the textbook **Path MTU Discovery blackhole**: somewhere the path's MTU is smaller than yours (a tunnel, VPN, or PPPoE link), and the ICMP "fragmentation needed" messages that *should* tell your host to shrink its packets are being **blocked by a firewall**. Your big packets vanish silently.

Diagnose by probing the path MTU with **do-not-fragment** pings, shrinking until they pass:
```
ping -M do -s 1472 -c 2 10.0.30.20      # 1472 + 28 = 1500 (standard Ethernet)
ping -M do -s 1400 -c 2 10.0.30.20      # try smaller if 1472 fails
```
The largest payload that succeeds, **+28**, is your working path MTU. `tracepath 10.0.30.20` discovers it automatically and shows where it drops.

Fixes: lower the interface MTU to match the path (`ip link set eth0 mtu 1400`), or **clamp TCP MSS** on the gateway (`iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`) so TCP negotiates a safe segment size. The proper fix is to **stop blocking ICMP type 3 code 4** so PMTUD can work.

### 6.5 Throughput

Measure it directly between two hosts (don't guess from a file copy that may be disk-bound):
```
# on the receiver:
iperf3 -s
# on the sender:
iperf3 -c <receiver-ip> -t 30
iperf3 -c <receiver-ip> -u -b 0    # UDP mode to measure loss/jitter
```
If throughput is far below the link speed, the usual culprits:
- **Loss/retransmits** capping the TCP window — check `ss -ti` for `retrans` and a small `cwnd`.
- **Bandwidth-Delay Product on high-latency links** — a fat, long path needs a big window. Confirm window scaling is on (`sysctl net.ipv4.tcp_window_scaling` = 1) and that socket buffers are large enough (`net.core.rmem_max`, `net.core.wmem_max`, `net.ipv4.tcp_rmem`, `net.ipv4.tcp_wmem`).
- **A duplex mismatch** (Part 2.2) or **NIC drops** (Part 2.3) underneath it all.

Inspect a live connection's TCP internals:
```
ss -ti
```
Look at `rtt:` (round-trip + variance), `cwnd:` (congestion window — small under loss), and `retrans:` (retransmits this connection). Small cwnd + nonzero retrans = the path is lossy and that's what's throttling you.

---

## Part 7 — TCP / socket-level problems (often "under load")

These show up as a healthy-looking network that falls over when busy. Counters are your friend here — `nstat` (since boot, or `nstat` alone for deltas) and `netstat -s`.

### 7.1 Overall socket health

```
ss -s
```
Gives totals by state. A huge **timewait** count or a runaway **estab** count points at the specific problems below.

### 7.2 Ephemeral port / TIME_WAIT exhaustion

**Symptom:** a busy client (app server hitting a database or API a lot) starts failing with **"cannot assign requested address"** (EADDRNOTAVAIL). It has run out of ephemeral source ports because thousands of recently-closed connections are stuck in **TIME_WAIT**.

```
ss -tan state time-wait | wc -l                 # how many TIME_WAIT
sysctl net.ipv4.ip_local_port_range             # size of the ephemeral pool
```
Mitigations: widen the port range; enable `net.ipv4.tcp_tw_reuse=1` (safe for outbound connections); and ideally **reuse connections** (connection pooling / keep-alive) so you're not churning sockets. *Do not* use the long-removed `tcp_tw_recycle`.

### 7.3 Accept-queue / SYN-backlog drops

**Symptom:** under bursts, clients see timeouts or resets connecting to a service that is *up* and listening. The kernel is dropping connections because a queue filled.

```
nstat -az | grep -iE 'ListenOverflows|ListenDrops|TCPReqQFullDrop|SyncookiesSent'
netstat -s | grep -iE 'listen|SYN'
```
- **`ListenOverflows` / "times the listen queue ... overflowed"** → the **accept queue** filled because the app isn't `accept()`ing fast enough, or the backlog is too small. Raise `net.core.somaxconn` *and* the app's listen backlog; on the listening socket, `ss -tlnp` Send-Q shows the effective limit.
- **SYN-flood-like drops / SynCookies firing** → raise `net.ipv4.tcp_max_syn_backlog`; SYN cookies kicking in protects you but can indicate real overload or an actual SYN flood.

### 7.4 Connection-tracking (conntrack) table full

**Symptom:** on a firewall/NAT box or any host using stateful netfilter, **intermittent packet drops under load**, and in the kernel log:
```
dmesg -T | grep -i conntrack
# nf_conntrack: table full, dropping packet
```
Check usage:
```
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
```
If `count` is near `max`, raise `nf_conntrack_max` (and the hashsize), or reduce churn. This one is invisible to most app-level debugging and only shows in the counters/kernel log — worth checking early on any NAT/firewall host.

### 7.5 Stuck connections / Recv-Q / Send-Q on established sockets

```
ss -tnp
```
On an **ESTAB** socket: a persistently nonzero **Recv-Q** means the *application isn't reading* data the kernel has (slow/stuck app, not the network). A persistently nonzero **Send-Q** means data isn't being acknowledged by the peer (network loss, or a stalled/blocked receiver). This cleanly separates "the network is stuck" from "the app is stuck."

---

## Part 8 — Application layer: HTTP and TLS

Once L4 is proven good but the *service* still misbehaves:

```
curl -v https://service.example.internal/health
```
`-v` shows DNS resolution, the TCP connect, the TLS handshake, request headers, and the response status — a one-shot view of where it breaks. Useful flags:
- `--resolve service.example.internal:443:10.0.30.20` → **bypass DNS** and force a specific IP (proves whether DNS or the server is at fault).
- `-I` → headers only. `--connect-timeout` / `--max-time` → bound the wait.

For TLS specifically:
```
openssl s_client -connect service.example.internal:443 -servername service.example.internal
```
Reveals the cert chain, expiry, and handshake errors. Common findings: **expired certificate**, **missing intermediate chain**, **wrong SNI/hostname mismatch**, or a **protocol/cipher mismatch** between client and server. `openssl x509 -noout -dates` on the cert checks validity dates.

---

## Part 9 — Intermittent and "only sometimes" problems

The hardest class. A method that works:

1. **Make it continuous and timestamped** so you catch it in the act:
   ```
   mtr -n --report -c 600 10.0.30.20            # 10 min of path stats
   while true; do date; curl -s -o /dev/null -w '%{http_code} %{time_total}\n' \
       http://10.0.30.20:8080/health; sleep 1; done | ts   # per-second probe (ts from moreutils)
   ```
2. **Correlate with load.** If failures track traffic peaks → suspect a *queue/table filling*: backlog drops (7.3), conntrack (7.4), ephemeral ports (7.2), or NIC ring drops (2.3). Watch the relevant counter over time:
   ```
   watch -n1 "nstat -az | grep -iE 'ListenOverflow|Retrans|Drop'"
   ```
3. **Correlate with a flap.** `dmesg -T` and `journalctl -k` for link up/down, NIC resets, or "duplicate address" appearing right when it breaks.
4. **Suspect duplicate IP / ARP** for *position-dependent* intermittency (works for some peers, not others, changes over minutes) — Part 3.1/3.3.
5. **Suspect asymmetric routing / rp_filter** if captures show requests arriving but replies never leaving, or only one direction is seen — Part 3.4.

---

## Part 10 — Symptom → likely cause quick index

| Symptom | Start at |
|---|---|
| No connectivity at all on a host | 2.1 (link), 3.1 (IP), 3.2 (route) |
| Can reach local subnet, nothing remote | 3.2 (default route / gateway) |
| Can't reach one host on the same subnet | 3.3 (ARP), 3.1 (duplicate IP) |
| "Connection refused" | 5.1 / 5.2 (service not listening or bound to 127.0.0.1, or REJECT) |
| "Connection timed out" | 5.1 / 5.3 (firewall DROP, host down, route) |
| "No route to host" / "Network unreachable" | 3.2 (route), 3.3 (ARP) |
| "Connection reset by peer" | 5.1 (app crash / middlebox), app logs |
| Connects then hangs on large transfers | 6.4 (MTU / PMTUD blackhole) |
| Name won't resolve (but `dig` works) | 4.1 (resolver stack: hosts/nsswitch/resolved) |
| `dig` itself times out | 4.3 (can't reach DNS server) |
| Everything feels laggy | 4.4 (slow DNS), 6.1 (latency) |
| Slow / low throughput | 2.2 (duplex), 6.2 (loss), 6.4 (MTU), 6.5 (window/buffers) |
| Fails only under load | 7.2 (ephemeral ports), 7.3 (backlog), 7.4 (conntrack), 2.3 (NIC drops) |
| Intermittent, position-dependent | 3.1/3.3 (duplicate IP / ARP), 3.4 (rp_filter) |
| Throughput fine, app still stuck | 7.5 (Recv-Q/Send-Q), 8 (app/TLS) |
| TLS/cert errors | 8 (openssl s_client) |

---

## Part 11 — One-page command appendix

```
LINK / NIC (L1-L2)
  ip -br link                       interfaces up/down + carrier
  ethtool eth0                      speed / duplex / link detected
  ethtool -S eth0 | grep -iE 'err|drop|crc|fifo|miss'   driver error stats
  ip -s link show eth0              rx/tx errors, dropped, collisions
  ethtool -g eth0                   ring buffer sizes (raise with -G)
  dmesg -T | grep -iE 'link|nic|carrier|reset'          hw/link events

IP / ROUTE / ARP (L3)
  ip -br addr                       addresses
  ip route ; ip route get <ip>      routing table + decision for a dest
  ip neigh                          ARP cache (INCOMPLETE = L2 problem)
  arping -D -I eth0 <ip>            duplicate-IP detection
  arping -I eth0 <gw>               L2 reachability to gateway
  sysctl net.ipv4.conf.all.rp_filter   reverse-path filtering (asym drops)

DNS
  getent hosts <name>               what the APP sees (NSS: hosts+dns)
  dig +short <name>                 pure DNS answer
  dig @<server> <name> ; dig +trace localize / walk delegation
  resolvectl status                 systemd-resolved real servers
  grep ^hosts /etc/nsswitch.conf    resolution order

REACHABILITY / PORTS (L4)
  ss -tlnp                          what's LISTENing (+ backlog in Send-Q)
  nc -vz <host> <port>              test a TCP port (refused/timeout/open)
  curl -v --connect-timeout 5 <url> full connect+TLS+HTTP trace
  timeout 3 bash -c '</dev/tcp/host/port'   no-nc port test
  iptables -L -n -v --line-numbers  firewall + counters (nft list ruleset)
  tcpdump -nni eth0 host <ip> and port <p>   ground truth (run on dest)

PERFORMANCE
  ping -c20 <ip>                    latency: avg + jitter(mdev)
  mtr -n -c100 --report <ip>        per-hop loss/latency (end-to-end = truth)
  ping -M do -s 1472 <ip>           path-MTU probe (largest that passes +28)
  tracepath <ip>                    auto path-MTU discovery
  iperf3 -s  /  iperf3 -c <ip> -t30 throughput between two hosts
  ss -ti dst <ip>                   rtt / cwnd / retrans per connection

SOCKET / UNDER-LOAD
  ss -s                             socket totals by state
  ss -tan state time-wait | wc -l   TIME_WAIT count (ephemeral exhaustion)
  nstat -az | grep -iE 'ListenOverflow|Retrans|Drop'   queue/loss counters
  sysctl net.netfilter.nf_conntrack_count nf_conntrack_max   conntrack usage

THE METHOD
  1 Reproduce minimally (curl/nc/ping, not the whole app)
  2 Walk the ladder: link -> IP/route -> DNS -> port -> app
  3 Name the symptom exactly (refused/timeout/reset/no-route)
  4 Compare to a known-good host on the same subnet
  5 Localize: test from source, from peer, from far end
  6 When unsure, tcpdump on the destination and watch the SYN
```

---

*Reminder: the fastest path through almost any of these is to (1) say the symptom precisely, (2) prove which layer it's at with one cheap test, and (3) only then start changing things — one variable at a time, re-testing after each. Most "mystery" network problems are a missing route, a service bound to 127.0.0.1, a silently-dropping firewall, a DNS resolver-stack quirk, or an MTU blackhole — check those five before reaching for anything exotic.*
