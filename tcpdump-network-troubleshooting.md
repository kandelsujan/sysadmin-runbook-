# tcpdump & NFS Network Troubleshooting Reference

A practical field guide for diagnosing network problems with `tcpdump`, with paired
client/server captures and an NFS-specific section. The organizing idea throughout:

> **No reply = availability/network problem. A fast reply carrying an error =
> configuration/state problem.** The presence, latency, and content of the reply
> tells you which world you're in before you touch a single config.

---

## Table of Contents

1. [Essential flags](#1-essential-flags)
2. [Find your interface first](#2-find-your-interface-first)
3. [BPF filters](#3-bpf-filters)
4. [Reading the output](#4-reading-the-output)
5. [Quick troubleshooting recipes](#5-quick-troubleshooting-recipes)
6. [Capture-to-file best practices](#6-capture-to-file-best-practices)
7. [TCP scenarios (client + server paired captures)](#7-tcp-scenarios)
8. [NFS scenarios](#8-nfs-scenarios)
9. [The unifying diagnostic framework](#9-the-unifying-diagnostic-framework)

---

## 1. Essential flags

```bash
tcpdump -i eth0          # capture on a specific interface
tcpdump -i any           # all interfaces (great when unsure)
tcpdump -n               # don't resolve IPs to hostnames (faster, clearer)
tcpdump -nn              # also don't resolve ports to names (80 stays 80)
tcpdump -v / -vv / -vvv  # increasing verbosity (TTL, IP id, options, RPC decode)
tcpdump -c 100           # stop after 100 packets
tcpdump -w file.pcap     # write raw packets to file (for Wireshark)
tcpdump -r file.pcap     # read back a saved capture
tcpdump -A               # print payload as ASCII (text protocols)
tcpdump -X               # print payload as hex + ASCII
tcpdump -e               # show link-layer (MAC) headers
tcpdump -s 0             # full packet capture (snaplen); modern default is already full
```

**The single most important habit: always use `-nn`.** DNS resolution on every packet
slows capture, can cause dropped packets, and clutters output. `-nn` shows raw IPs and
ports — which is what you actually want when troubleshooting.

---

## 2. Find your interface first

```bash
ip -br addr        # list interfaces and their IPs, briefly
tcpdump -D         # list interfaces tcpdump can see
```

When you don't know where traffic flows, start with `-i any` to cast a wide net, then
narrow down.

---

## 3. BPF filters

tcpdump uses **BPF (Berkeley Packet Filter)** syntax. Filtering at capture time is far
better than capturing everything and grepping — the kernel discards unwanted packets
before they ever reach userspace.

**By host / network:**
```bash
tcpdump -nn host 10.0.0.5              # to OR from this IP
tcpdump -nn src host 10.0.0.5          # only source
tcpdump -nn dst host 10.0.0.5          # only destination
tcpdump -nn net 10.0.0.0/24            # whole subnet
```

**By port / protocol:**
```bash
tcpdump -nn port 443                   # to OR from port 443
tcpdump -nn dst port 53                # outbound DNS queries
tcpdump -nn tcp port 22                # SSH only
tcpdump -nn udp port 53                # DNS
tcpdump -nn icmp                       # ping / unreachables
tcpdump -nn portrange 8000-8100        # a range of ports
```

**Combining with `and` / `or` / `not` (the real power):**
```bash
tcpdump -nn host 10.0.0.5 and port 443
tcpdump -nn 'tcp port 80 or tcp port 443'
tcpdump -nn 'host 10.0.0.5 and not port 22'   # exclude your own SSH session!
tcpdump -nn 'src 10.0.0.5 and dst port 3306'  # who's hitting MySQL from this host
```

> **The `not port 22` trick is essential.** If you're SSH'd into the box you're
> capturing on, your own session traffic floods the output. Excluding it is a
> near-universal first move.

---

## 4. Reading the output

A typical TCP line:

```
14:23:01.123456 IP 10.0.0.5.51234 > 10.0.0.9.443: Flags [S], seq 12345, win 64240, length 0
```

| Field | Meaning |
|---|---|
| `14:23:01.123456` | timestamp |
| `10.0.0.5.51234 > 10.0.0.9.443` | source IP.port → dest IP.port (last dotted number = port) |
| `Flags [S]` | TCP flags (most useful field for troubleshooting) |
| `seq` / `ack` | sequence / acknowledgement numbers |
| `win` | TCP window size |
| `length` | payload bytes |

**TCP flags decoder — memorize these:**

| Flag | Meaning |
|---|---|
| `[S]`  | SYN — connection attempt |
| `[S.]` | SYN-ACK — server accepting (the `.` means ACK) |
| `[.]`  | plain ACK |
| `[P.]` | PUSH+ACK — data being sent |
| `[F.]` | FIN+ACK — graceful close |
| `[R]` / `[R.]` | RESET — connection refused / forcibly killed |

A healthy connection opens with the handshake **`[S]` → `[S.]` → `[.]`**.

- `[S]` going out repeatedly with no `[S.]` back → server isn't responding (firewall
  drop, wrong port, host down).
- `[R]` immediately after `[S]` → connection **refused** (nothing listening, or a
  firewall actively rejecting).

---

## 5. Quick troubleshooting recipes

**Is this host reachable / responding?**
```bash
tcpdump -nn icmp
```

**Connection failing — handshake or refusal?**
```bash
tcpdump -nn "host 10.0.0.9 and port 443"
# [S] with no [S.]  -> dropped (firewall/host down)
# [S] then [R.]     -> refused (nothing listening)
# full handshake    -> network is fine, problem is higher up
```

**Is DNS working?**
```bash
tcpdump -nn port 53
```

**Who is opening new connections to my server?**
```bash
tcpdump -nn -i eth0 'dst port 80 and tcp[tcpflags] & tcp-syn != 0'
```

**Inspect actual HTTP content (text protocols only):**
```bash
tcpdump -nn -A 'tcp port 80 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)'
# the filter strips empty ACKs so you only see packets with payload
```
(HTTPS payload is encrypted — you can still see the handshake and timing.)

**Capture for later analysis in Wireshark:**
```bash
tcpdump -nn -i eth0 -w capture.pcap host 10.0.0.9
# Ctrl-C to stop, then open capture.pcap in Wireshark
```

> **Pro workflow:** capture on the server with tcpdump, analyze on your laptop with
> Wireshark. "Follow TCP Stream," protocol decoding, and graphs beat reading raw
> tcpdump for anything complex. **tcpdump captures; Wireshark analyzes.**

---

## 6. Capture-to-file best practices

Ring buffers so you don't fill the disk:

```bash
tcpdump -nn -i eth0 -w cap.pcap -C 100 -W 10
# -C 100  : rotate to a new file every 100 MB
# -W 10   : keep at most 10 files (rolling buffer)

tcpdump -nn -i eth0 -w cap-%Y%m%d-%H%M%S.pcap -G 3600
# -G 3600 : start a new timestamped file every hour
```

Headers only (saves space on busy links):
```bash
tcpdump -nn -s 96 ...   # capture only first 96 bytes (headers, not payload)
```

> For **paired captures**, sync clocks with NTP/chrony on both hosts or timestamps
> won't line up. Use a **tight, identical filter on both ends** so captures compare
> line for line.

---

## 7. TCP scenarios

Each scenario shows the client command + output, the server command + output, and the
reasoning chain. The key insight: several failures look **identical from one end** —
only paired capture localizes the fault to a *segment* of the path.

### 7.1 "I can't connect to the web server"

Client trying to reach `10.0.0.9:443`. It hangs. On the client:
```bash
tcpdump -nn host 10.0.0.9 and port 443
```

**Output A — repeated SYNs, total silence:**
```
14:02:11.001 IP 10.0.0.5.49620 > 10.0.0.9.443: Flags [S], seq 1001, win 64240, length 0
14:02:12.002 IP 10.0.0.5.49620 > 10.0.0.9.443: Flags [S], seq 1001, win 64240, length 0
14:02:14.005 IP 10.0.0.5.49620 > 10.0.0.9.443: Flags [S], seq 1001, win 64240, length 0
```
SYNs go out (your side is fine), nothing comes back. Retransmits at ~1s, 2s, 4s =
exponential backoff = "no response at all." Same `seq 1001` confirms retransmits, not
new attempts. → **Packet silently dropped** (firewall DROP rule, host down, no return
route).

**Output B — SYN answered with RST:**
```
14:05:20.101 IP 10.0.0.5.49622 > 10.0.0.9.443: Flags [S], seq 2001, win 64240, length 0
14:05:20.102 IP 10.0.0.9.443 > 10.0.0.5.49622: Flags [R.], seq 0, ack 2002, win 0, length 0
```
Host is alive and slammed the door within 1ms. → **Connection refused** — nothing
listening on 443, or a firewall set to *reject*. Check: `ss -tlnp | grep :443`.

**Output C — full handshake, then nothing:**
```
14:08:30.201 IP 10.0.0.5.49624 > 10.0.0.9.443: Flags [S], seq 3001, win 64240, length 0
14:08:30.202 IP 10.0.0.9.443 > 10.0.0.5.49624: Flags [S.], seq 9001, ack 3002, win 65160, length 0
14:08:30.202 IP 10.0.0.5.49624 > 10.0.0.9.443: Flags [.], ack 9002, win 64240, length 0
```
Perfect `[S]` → `[S.]` → `[.]`. TCP is healthy. → Problem is **higher up** (TLS, app
hang, slow backend, auth). Stop looking at tcpdump's connection view; read app logs.

> **dropped / refused / established** is the single most useful pattern in tcpdump —
> it tells you which layer to blame immediately.

### 7.1 (paired) — Server-side captures that disambiguate

For the "silence" case (Output A), the client view is ambiguous. Run on the **server**:
```bash
tcpdump -nn -i any host 10.0.0.5 and port 443
```

| Server sees | Conclusion | Confirm with |
|---|---|---|
| **Nothing** | Drop is **upstream of the server** (path firewall, security group, routing) | cloud SG / router ACL |
| SYN arrives, **no reply generated** | Server **local firewall drop** | `nft list ruleset \| grep 443`; `iptables -L INPUT -v -n` (watch DROP counters tick up by your retransmit count); `ss -tlnp \| grep :443` |
| SYN arrives, **`[S.]` sent** but client never sees it | **Return-path break** | `ip route get 10.0.0.5`; `sysctl net.ipv4.conf.all.rp_filter` |

For the RST case (Output B), the server's **kernel** auto-generates the RST when no
socket listens (note `seq 0, win 0` = kernel-generated). Confirm:
```bash
ss -tlnp | grep :443         # empty => nothing listening
systemctl status nginx
```
**Common gotcha:** service bound to `127.0.0.1:443` instead of `0.0.0.0:443` — only
local connections work, remote SYNs get refused.

### 7.2 Flaky DNS

```bash
tcpdump -nn port 53
```
```
15:10:01.100 IP 10.0.0.5.34221 > 8.8.8.8.53: 4512+ A? api.example.com. (33)
15:10:01.142 IP 8.8.8.8.53 > 10.0.0.5.34221: 4512 1/0/0 A 93.184.216.34 (49)
15:10:06.200 IP 10.0.0.5.51002 > 8.8.8.8.53: 9981+ A? db.internal.lan. (33)
15:10:11.205 IP 10.0.0.5.51002 > 8.8.8.8.53: 9981+ A? db.internal.lan. (33)
```
Reading DNS: `4512+` = query ID, `+` = recursion desired. `A?` = asking for an A
record. `1/0/0` = 1 answer, 0 authority, 0 additional.

First query resolves in ~42ms. The **internal** name retransmits with no answer. →
Internal queries are going to a **public** resolver that doesn't know them. Not an
outage — a **resolver config bug**. Confirm:
```bash
resolvectl status        # which server for which domain?
cat /etc/resolv.conf
```
If you control the internal resolver, capture there — the query never arriving proves
it's being sent to the wrong place:
```bash
tcpdump -nn -i any port 53 and host 10.0.0.5   # (run on internal DNS server)
```

### 7.3 Connection stalls mid-transfer

```bash
tcpdump -nn host 10.0.0.9 and port 8080
```

**Retransmissions:**
```
16:20:05.001 IP 10.0.0.5.40010 > 10.0.0.9.8080: Flags [P.], seq 1:1461, ack 1, win 502, length 1460
16:20:05.301 IP 10.0.0.5.40010 > 10.0.0.9.8080: Flags [P.], seq 1:1461, ack 1, win 502, length 1460
16:20:05.901 IP 10.0.0.5.40010 > 10.0.0.9.8080: Flags [P.], seq 1:1461, ack 1, win 502, length 1460
```
Same segment re-sent with growing gaps, no ACK for `seq 1461`. → **Packet loss**, or
receiver stopped acking (crashed/overwhelmed, or a stateful firewall dropped the flow).

Server side — does the data arrive?
```bash
tcpdump -nn -i any host 10.0.0.5 and port 8080
```
- Segments never appear → loss on **client→server** path.
- Segments arrive but client never gets ACK → loss on **return** path.

Corroborate:
```bash
ip -s link show eth0           # rising RX/TX errors, dropped, overrun
netstat -s | grep -i retrans   # systemwide retransmit counters
```

**Zero window:**
```
16:25:10.001 IP 10.0.0.9.8080 > 10.0.0.5.40010: Flags [.], ack 50000, win 0, length 0
16:25:11.000 IP 10.0.0.9.8080 > 10.0.0.5.40010: Flags [.], ack 50000, win 0, length 0
```
Server advertises `win 0` = "my buffer is full, stop sending." → **Not network loss —
flow control.** The receiving app isn't reading its socket fast enough. Confirm on the
server:
```bash
ss -tn dst 10.0.0.5     # large, stuck Recv-Q = data in kernel buffer, app not read()ing
top / htop              # app pegged or blocked?
ps -o stat= -p <pid>    # 'D' = uninterruptible sleep (usually disk I/O)
```

### 7.4 Asymmetric routing / one-way reachability

This is the scenario **only** paired capture can solve — from the client it looks
identical to 7.1 Output A.

Client:
```
17:00:01.001 IP 10.0.0.5.55000 > 10.0.0.9.443: Flags [S], seq 7001, win 64240, length 0
17:00:02.002 IP 10.0.0.5.55000 > 10.0.0.9.443: Flags [S], seq 7001, win 64240, length 0
```
Server:
```bash
tcpdump -nn -i any host 10.0.0.5 and port 443
```
```
17:00:01.001 IP 10.0.0.5.55000 > 10.0.0.9.443: Flags [S], seq 7001, win 64240, length 0
17:00:01.001 IP 10.0.0.9.443 > 10.0.0.5.55000: Flags [S.], seq 8001, ack 7002, win 65160, length 0
```
Server receives every SYN and **sends a SYN-ACK every time**, but the client never sees
one. → **Return-path failure** (asymmetric routing, `rp_filter`, stateful device on the
return path). Confirm:
```bash
ip route get 10.0.0.5                  # reply leaving via an unexpected interface?
sysctl net.ipv4.conf.all.rp_filter     # 1 = strict, may drop asymmetric replies
conntrack -L | grep 10.0.0.5           # is the connection tracked, in what state?
```

---

## 8. NFS scenarios

> **Know your version first** — it changes what to capture.
> - **NFSv4**: single port **2049/tcp**. Self-contained, firewall-friendly. Capturing
>   `port 2049` shows everything.
> - **NFSv3**: a constellation — **rpcbind/portmapper 111**, **mountd** (dynamic port),
>   **nfsd 2049**, plus **lockd/nlockmgr** and **statd**. Problems often hide on 111 or
>   mountd, not 2049.

Check on the client:
```bash
nfsstat -m          # shows vers=4.x or vers=3 per mount, plus negotiated options
mount | grep nfs
```

> **Always capture NFS with `-s 0 -v`** so the RPC/NFS procedure names and error codes
> are decoded, not truncated.

### 8.1 Mount hangs / "server not responding, still trying"

`dmesg`: `nfs: server 10.0.0.9 not responding, still trying`. ("still trying" = a
**hard** mount; it hangs forever rather than erroring. A **soft** mount would time out
and return an I/O error. Hard is the default and usually correct for data integrity.)

Client:
```bash
tcpdump -nn -v -s 0 host 10.0.0.9 and port 2049
```
```
14:00:01.001 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x3a1f 160 getattr fh 0,1/16
14:00:01.301 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x3a1f 160 getattr fh 0,1/16
14:00:01.901 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x3a1f 160 getattr fh 0,1/16
```
Same **`xid 0x3a1f`** retransmits with backoff, no reply. (`xid` = RPC transaction ID,
the RPC equivalent of the TCP seq number; same xid = retransmits of one request.) This
is the NFS-layer version of "SYN with no SYN-ACK."

Server:
```bash
tcpdump -nn -v -s 0 host 10.0.0.5 and port 2049
```

| Server sees | Conclusion | Confirm with |
|---|---|---|
| **Nothing** | Drop **upstream of server** (firewall 2049, SG, routing) | `ss -tlnp \| grep 2049`; `nft list ruleset \| grep 2049` |
| Request arrives, **no reply** | **nfsd wedged / thread exhaustion** (all threads blocked on slow storage) | `systemctl status nfs-server`; `nfsstat -s`; `cat /proc/net/rpc/nfsd` (th line = thread utilization); `iostat -x 1`; `dmesg` for storage errors |
| nfsd **replies**, client never sees it | **Return-path break** | `ip route get 10.0.0.5`; `sysctl net.ipv4.conf.all.rp_filter` |

For thread exhaustion: if the `th` line shows threads pegged at 100%, the backing
storage is the real bottleneck. Bump `RPCNFSDCOUNT` only if threads are saturated *and*
storage has headroom.

### 8.2 "access denied" / Permission denied

Mount fails fast, or every access returns `Permission denied`. Almost always an
**export config** problem — the capture confirms it by showing a fast reply *carrying
an error*.

Client:
```bash
tcpdump -nn -v -s 0 host 10.0.0.9 and port 2049
```
```
14:10:05.001 IP 10.0.0.5.812 > 10.0.0.9.2049: ... NFS request xid 0x5c20 access fh 0,1/16 0x2d
14:10:05.002 IP 10.0.0.9.2049 > 10.0.0.5.812: ... NFS reply xid 0x5c20 access ERROR: Permission denied
```
There **is** a reply, in 1ms. Network is perfect; server deliberately refuses. NFS
error 13 (`NFS3ERR_ACCES` / `NFS4ERR_ACCESS`) = export policy or file permissions
reject this client/user.

Server — the heart of it:
```bash
exportfs -v
```
```
/data/shared   10.0.0.0/24(ro,root_squash,sync,no_subtree_check)
```
Two common culprits:
1. **`ro` when you need `rw`** — read-only export; writes denied. Re-export with `rw`.
2. **`root_squash`** (the default) — client root (uid 0) maps to `nobody`; root-owned
   writes get squashed. Fix is usually correct uid/gid alignment or ownership — **not**
   blindly `no_root_squash` (that's a security hole).

Also verify the client IP is in the exported subnet, and reload after editing
`/etc/exports`:
```bash
showmount -e 10.0.0.9     # (v3/mountd) lists exports and allowed clients
exportfs -ra              # changes to /etc/exports don't apply until you do this
```

### 8.3 Stale file handle (ESTALE)

Worked, then `ls` returns `Stale file handle` until remount.

Client:
```bash
tcpdump -nn -v -s 0 host 10.0.0.9 and port 2049
```
```
14:20:11.001 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x7a01 getattr fh 0,7/2031
14:20:11.002 IP 10.0.0.9.2049 > 10.0.0.5.756: ... NFS reply xid 0x7a01 getattr ERROR: Stale NFS file handle
```
Reply is instant — server-state problem, not connectivity. Error 70
(`NFS3ERR_STALE`): the client holds a file handle the server no longer recognizes (a
handle encodes fsid + inode; if either changes underneath, it goes stale).

Server causes / fix:
```bash
exportfs -v
cat /proc/fs/nfs/exports
```
- Exported FS unmounted/remounted (storage reattached) → device number / fsid changed.
  **Pin a stable `fsid=` so handles survive remounts:**
  ```
  /data/shared 10.0.0.0/24(rw,sync,fsid=1234,no_subtree_check)
  ```
- File/dir the client had open was deleted/replaced out-of-band.
- Export edited and `exportfs -ra` regenerated handles.

Client recovery = remount; durable fix = stable `fsid` on the server.

### 8.4 NFS slow / stalls under load — the MTU trap

Mount works, small ops fine, large reads/writes crawl or hang.

Cheap client signal first (no tcpdump):
```bash
nfsstat -c
```
```
Client rpc stats:
calls      retrans    authrefrsh
1500342    48201      0
```
High **retrans** ratio (~3% here; >0.1% sustained is suspect) = RPCs timing out and
resending → loss/timeouts, not server logic.

Client capture during a large write:
```bash
tcpdump -nn -v -s 0 host 10.0.0.9 and port 2049
```
```
14:30:01.001 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x9f01 write fh 0,7/2031 65536 bytes @ 0
14:30:01.301 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x9f01 write fh 0,7/2031 65536 bytes @ 0
14:30:01.901 IP 10.0.0.5.756 > 10.0.0.9.2049: ... NFS request xid 0x9f01 write fh 0,7/2031 65536 bytes @ 0
```
Large WRITEs (`65536` = negotiated `wsize`) retransmit endlessly while small GETATTRs
went through. **Small ops succeed, large ops vanish** = fingerprint of an
**MTU / jumbo-frame mismatch**.

Mechanism: a 64KB write becomes many full-MTU packets. If client+server use jumbo
frames (MTU 9000) but a switch/bond in between only handles 1500 — with DF set — the
big frames are silently dropped while small control packets sail through.

Server confirms (small requests appear, large WRITE data never arrives):
```bash
tcpdump -nn -v -s 0 host 10.0.0.5 and port 2049
```
Confirm MTU end to end:
```bash
ip link show eth0 | grep mtu          # on BOTH client and server — do they match?
ping -M do -s 8972 10.0.0.9           # 8972 + 28 = 9000; fails if path can't do jumbo
ping -M do -s 1472 10.0.0.9           # 1472 + 28 = 1500; should always work
```
If 1472 works and 8972 fails ("Frag needed and DF set" or silence) → jumbo-frame black
hole. Fix: consistent MTU across every hop, or mitigate by shrinking NFS payloads:
```bash
mount -o remount,rsize=8192,wsize=8192 /mnt/share
```
If MTU is fine and you just see scattered retransmits, fall back to generic loss checks
(`ip -s link`, `netstat -s`, overloaded switch/NIC offload bug).

### 8.5 (v3 only) "RPC: Program not registered" / mount fails instantly

On v3, mount dies immediately with `requested NFS version or transport protocol is not
supported` / `RPC: Program not registered`. The problem is the **portmapper layer** —
capture **111**, not 2049.

Client:
```bash
tcpdump -nn -v -s 0 host 10.0.0.9 and port 111
```
```
14:40:01.001 IP 10.0.0.5.901 > 10.0.0.9.111: ... RPC call getport prog 100005 (mountd)
14:40:01.002 IP 10.0.0.9.111 > 10.0.0.5.901: ... RPC reply getport PORT=0
```
Client asks rpcbind "what port is mountd (prog 100005) on?" — reply **`PORT=0`** = not
registered. mountd (or rpcbind) isn't running.

Server:
```bash
rpcinfo -p localhost
```
```
program vers proto   port  service
100000    4   tcp    111  portmapper
100003    3   tcp   2049  nfs
# ... but no 100005 (mountd) line!
```
Missing `mountd` (100005) or `nlockmgr` (100021) → those daemons didn't register.
Restart so RPC services re-register:
```bash
systemctl restart nfs-server rpcbind
rpcinfo -p localhost      # verify mountd, nlockmgr, status now appear
```

> This entire class of failure disappears on **NFSv4** — one port, no portmapper, no
> dynamic mountd/lockd. Strong argument for moving mounts to v4.

---

## 9. The unifying diagnostic framework

When you look at output, ask in order:

1. **Are my packets even leaving?** (Outbound SYNs/requests → your side works.)
2. **Is anything coming back?** (Nothing → drop. RST → refused. Reply → reachable.)
3. **Did the handshake complete?** (`[S] [S.] [.]` → blame the app, not the network.)
4. **If established, is data flowing or retransmitting?** (Retransmits → loss; `win 0`
   → receiver app bottleneck.)
5. **Does each side see what the other sent?** (Capture both ends → localize one-way
   breaks.)

### TCP quick reference

| Symptom | tcpdump shows | Means | Confirm with |
|---|---|---|---|
| SYN absent on server | nothing on server | drop upstream of server | cloud SG / router ACL / path firewall |
| SYN present, no reply | request lands, silence | server firewall drop | `nft list ruleset`, `iptables -vL` counters |
| SYN → RST | instant `[R.]` | nothing listening | `ss -tlnp`, `systemctl status` |
| Reply sent, not received | `[S.]` on server only | return-path break | `ip route get`, `rp_filter`, `conntrack -L` |
| Repeated retransmits | same seq resent | packet loss (which dir?) | `ip -s link`, `netstat -s` |
| `win 0` advertised | zero window | receiver app bottleneck | `ss -tn` Recv-Q, process `D` state |

### NFS quick reference

| Symptom | Wire signature | Means | Confirm on server |
|---|---|---|---|
| Hang, "still trying" | RPC req retransmits, **no reply** | unreachable / nfsd wedged / return-path | request present? → `nfsstat -s`, `/proc/net/rpc/nfsd` th line, `iostat` |
| Permission denied | **fast reply** `ERROR: Permission denied` (13) | export/permission/squash config | `exportfs -v`, `showmount -e`, `exportfs -ra` |
| Stale file handle | **fast reply** `ERROR: Stale` (70) | fsid/inode changed under client | `exportfs -v`, pin `fsid=` |
| Slow, small-ok/large-hang | large WRITE/READ xid retransmits | MTU / jumbo-frame black hole | `ip link mtu`, `ping -M do -s 8972` |
| Generic slow + retrans | scattered retransmits | packet loss / overload | `nfsstat -c`, `ip -s link`, `netstat -s` |
| Mount fails instantly (v3) | port 111 `getport ... PORT=0` | rpcbind/mountd not registered | `rpcinfo -p`, restart `rpcbind`/`nfs-server` |

### The two master principles

1. **No reply = availability/network problem. A fast reply carrying an error =
   configuration/state problem.** This holds at every layer — TCP RST vs. silence, NFS
   `ERROR:` vs. retransmit.
2. **Paired capture localizes faults to a path segment.** Many failures look identical
   from one vantage point (a dropped SYN and a lost SYN-ACK are indistinguishable on the
   client). Capturing both ends and comparing — *present here, absent there* — pins the
   break to forward path, server, or return path. Sync clocks and use identical filters
   so the two captures line up.
