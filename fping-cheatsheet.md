# fping Cheatsheet for Linux Sysadmins

`fping` is like `ping` on steroids — instead of pinging one host at a time and waiting, it pings many hosts in parallel, in round-robin, and exits with a useful return code. Ideal for sweeping subnets, scripting health checks, and quickly finding what’s alive.

-----

## Installation

```bash
# Debian / Ubuntu
sudo apt install fping

# RHEL / CentOS / Rocky / Alma (EPEL)
sudo dnf install epel-release && sudo dnf install fping

# Arch
sudo pacman -S fping

# Check version
fping -v
```

-----

## Exit Codes (critical for scripting)

|Code|Meaning                        |
|----|-------------------------------|
|0   |All hosts replied              |
|1   |Some/all hosts unreachable     |
|2   |Any IP addresses were not found|
|3   |Invalid command-line arguments |
|4   |System call failure            |

-----

## Basic Syntax

```bash
fping [options] [hosts...]
```

-----

## Core Use Cases

### 1. Quick check of a single host

```bash
$ fping 8.8.8.8
8.8.8.8 is alive
```

### 2. Check multiple hosts at once

```bash
$ fping 8.8.8.8 1.1.1.1 192.168.1.1 10.99.99.99
8.8.8.8 is alive
1.1.1.1 is alive
192.168.1.1 is alive
ICMP Host Unreachable from 192.168.1.1 for ICMP Echo sent to 10.99.99.99
10.99.99.99 is unreachable
```

### 3. Sweep a subnet with `-g` (generate range)

Two forms — CIDR or start/end:

```bash
$ fping -a -g 192.168.1.0/24 2>/dev/null
192.168.1.1
192.168.1.10
192.168.1.42
192.168.1.105
192.168.1.254
```

```bash
$ fping -a -g 10.0.0.1 10.0.0.20 2>/dev/null
10.0.0.1
10.0.0.5
10.0.0.17
```

- `-a` shows **only alive** hosts
- `-g` generates the target list
- `2>/dev/null` hides the noisy “unreachable” lines on stderr

### 4. Show only unreachable hosts

```bash
$ fping -u -g 192.168.1.0/24 2>/dev/null
192.168.1.2
192.168.1.3
192.168.1.4
...
```

### 5. Read targets from a file

```bash
$ cat hosts.txt
web01.example.com
web02.example.com
db01.example.com
10.0.0.50

$ fping -f hosts.txt
web01.example.com is alive
web02.example.com is alive
db01.example.com is alive
10.0.0.50 is unreachable
```

Or via stdin:

```bash
$ cat hosts.txt | fping
```

-----

## Continuous / Statistics Modes

### 6. Loop mode `-l` (ping forever, like `ping`)

```bash
$ fping -l 8.8.8.8
8.8.8.8 : [0], 84 bytes, 12.3 ms (12.3 avg, 0% loss)
8.8.8.8 : [1], 84 bytes, 11.8 ms (12.0 avg, 0% loss)
8.8.8.8 : [2], 84 bytes, 13.1 ms (12.4 avg, 0% loss)
^C
8.8.8.8 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 11.8/12.4/13.1
```

### 7. Count mode `-c N` (send N pings, get stats)

```bash
$ fping -c 4 8.8.8.8 1.1.1.1
8.8.8.8 : [0], 84 bytes, 11.9 ms (11.9 avg, 0% loss)
1.1.1.1 : [0], 84 bytes, 10.2 ms (10.2 avg, 0% loss)
8.8.8.8 : [1], 84 bytes, 12.4 ms (12.1 avg, 0% loss)
1.1.1.1 : [1], 84 bytes,  9.8 ms (10.0 avg, 0% loss)
8.8.8.8 : [2], 84 bytes, 11.5 ms (11.9 avg, 0% loss)
1.1.1.1 : [2], 84 bytes, 10.0 ms (10.0 avg, 0% loss)
8.8.8.8 : [3], 84 bytes, 12.1 ms (12.0 avg, 0% loss)
1.1.1.1 : [3], 84 bytes, 10.5 ms (10.1 avg, 0% loss)

8.8.8.8 : xmt/rcv/%loss = 4/4/0%, min/avg/max = 11.5/12.0/12.4
1.1.1.1 : xmt/rcv/%loss = 4/4/0%, min/avg/max = 9.8/10.1/10.5
```

### 8. Summary-only `-q` (quiet) + count

Great for batch jobs — only the final stats are shown:

```bash
$ fping -q -c 10 8.8.8.8 1.1.1.1
8.8.8.8 : xmt/rcv/%loss = 10/10/0%, min/avg/max = 11.4/12.1/13.2
1.1.1.1 : xmt/rcv/%loss = 10/10/0%, min/avg/max = 9.7/10.3/11.1
```

### 9. Statistics mode `-s` (overall summary)

```bash
$ fping -s -c 3 8.8.8.8 1.1.1.1
8.8.8.8 : [0], 84 bytes, 11.9 ms (11.9 avg, 0% loss)
1.1.1.1 : [0], 84 bytes, 10.2 ms (10.2 avg, 0% loss)
...

       2 targets
       2 alive
       0 unreachable
       0 unknown addresses

       0 timeouts (waiting for response)
       6 ICMP Echos sent
       6 ICMP Echo Replies received
       0 other ICMP received

 9.80 ms (min round trip time)
 11.1 ms (avg round trip time)
 12.4 ms (max round trip time)
        2.041 sec (elapsed real time)
```

-----

## Tuning Timing & Behavior

|Flag  |Purpose                                       |Default|
|------|----------------------------------------------|-------|
|`-i N`|Interval (ms) between pings to different hosts|10 ms  |
|`-p N`|Period (ms) between pings to the **same** host|1000 ms|
|`-t N`|Initial timeout (ms) waiting for first reply  |500 ms |
|`-r N`|Retry count                                   |3      |
|`-B N`|Backoff multiplier for timeout                |1.5    |
|`-c N`|Send N pings per target                       |—      |
|`-C N`|Like `-c` but shows per-probe times           |—      |

### Example: faster subnet sweep

```bash
$ fping -a -g 10.0.0.0/24 -i 1 -r 1 -t 100 2>/dev/null
10.0.0.1
10.0.0.12
10.0.0.45
```

- `-i 1` = 1 ms between hosts
- `-r 1` = only retry once
- `-t 100` = 100 ms timeout

### `-C` for per-probe detail (useful for jitter/loss analysis)

```bash
$ fping -C 5 -q 8.8.8.8
8.8.8.8 : 11.94 12.03 11.87 - 12.41
```

A `-` means a dropped packet at that probe number.

-----

## Useful Output Flags

|Flag  |Effect                                               |
|------|-----------------------------------------------------|
|`-a`  |Show alive hosts only                                |
|`-u`  |Show unreachable hosts only                          |
|`-A`  |Show targets as IP addresses (no DNS in output)      |
|`-n`  |Reverse-resolve IPs to names                         |
|`-d`  |Same as `-n`, show DNS names                         |
|`-e`  |Show elapsed (RTT) time per reply                    |
|`-D`  |Print timestamp before each line                     |
|`-o`  |Show accumulated outage time (with `-l` or `-c`)     |
|`-q`  |Quiet — only final summary                           |
|`-Q N`|Quiet but emit summary every N seconds (long-running)|

### `-D` timestamps (nice for logs)

```bash
$ fping -D -l 8.8.8.8
[1716825601.123456] 8.8.8.8 : [0], 84 bytes, 12.1 ms (12.1 avg, 0% loss)
[1716825602.124891] 8.8.8.8 : [1], 84 bytes, 11.8 ms (11.9 avg, 0% loss)
```

### `-Q` periodic summaries

```bash
$ fping -l -Q 10 8.8.8.8 1.1.1.1
[10s] 8.8.8.8 : xmt/rcv/%loss = 10/10/0%, min/avg/max = 11.4/12.0/13.1
[10s] 1.1.1.1 : xmt/rcv/%loss = 10/10/0%, min/avg/max = 9.7/10.2/10.8
[20s] 8.8.8.8 : xmt/rcv/%loss = 20/20/0%, min/avg/max = 11.4/12.1/13.4
[20s] 1.1.1.1 : xmt/rcv/%loss = 20/20/0%, min/avg/max = 9.7/10.3/11.0
```

-----

## IPv6

```bash
# Force IPv6
$ fping -6 2606:4700:4700::1111
2606:4700:4700::1111 is alive

# Force IPv4
$ fping -4 one.one.one.one
```

On most distros there’s a separate `fping6` binary, but modern fping accepts `-6`.

-----

## Packet Size, TOS, TTL, Source

```bash
# Larger payload (default is 56 bytes ICMP data + 28 header = 84)
$ fping -b 1400 8.8.8.8

# Set TTL
$ fping -H 64 8.8.8.8

# Set TOS / DSCP (e.g. EF = 0xB8 for VoIP testing)
$ fping -O 184 voip-gw.example.com

# Bind to a specific source interface / IP
$ fping -I eth0 8.8.8.8
$ fping -S 192.168.1.50 8.8.8.8
```

-----

## Real-World Sysadmin Recipes

### Quickly find live hosts on a /24

```bash
fping -a -g 192.168.1.0/24 2>/dev/null
```

### Build a hosts inventory

```bash
fping -a -A -g 10.10.0.0/22 2>/dev/null > live-hosts.txt
wc -l live-hosts.txt
```

### Health check in a script (using exit code)

```bash
#!/bin/bash
if fping -q -c 3 -t 200 db01.internal; then
    echo "DB is healthy"
else
    echo "DB unreachable — alerting" | mail -s "DB DOWN" oncall@example.com
fi
```

### Find which hosts in a list are DOWN

```bash
fping -u -f /etc/ansible/all-hosts.txt 2>/dev/null
```

### Continuous loss monitoring with timestamps to a logfile

```bash
fping -l -D -Q 60 -f critical-hosts.txt >> /var/log/fping-monitor.log 2>&1 &
```

### Compare latency across a fleet quickly

```bash
$ fping -q -c 20 web01 web02 web03 db01 cache01
web01   : xmt/rcv/%loss = 20/20/0%, min/avg/max = 0.42/0.51/0.78
web02   : xmt/rcv/%loss = 20/20/0%, min/avg/max = 0.45/0.52/0.81
web03   : xmt/rcv/%loss = 20/19/5%, min/avg/max = 0.44/0.58/2.11
db01    : xmt/rcv/%loss = 20/20/0%, min/avg/max = 0.31/0.39/0.55
cache01 : xmt/rcv/%loss = 20/20/0%, min/avg/max = 0.28/0.34/0.49
```

→ web03 has 5% loss, worth investigating.

### Trace which gateways are reachable

```bash
fping -a $(ip route | awk '/default/ {print $3}') 192.168.1.1 10.0.0.1
```

### Combine with `xargs` for parallel ops on alive hosts

```bash
fping -a -g 10.10.10.0/24 2>/dev/null | \
    xargs -n1 -P10 -I{} ssh -o ConnectTimeout=3 {} uptime
```

### Use in cron for SLA-style logging

```cron
*/5 * * * * /usr/bin/fping -q -c 10 -Q 0 -D core-router edge-router uplink-gw >> /var/log/net-sla.log 2>&1
```

-----

## Permissions Note

`fping` traditionally needs raw sockets (root or `CAP_NET_RAW`). On modern systems it’s usually installed setuid root or with the capability set:

```bash
$ getcap $(which fping)
/usr/bin/fping = cap_net_raw+ep
```

If it’s not, you’ll see:

```
fping: can't create socket (must run as root?)
```

Fix with:

```bash
sudo setcap cap_net_raw+ep /usr/bin/fping
```

-----

## Common Pitfalls

- **Redirect stderr.** Unreachable lines go to stderr. Use `2>/dev/null` to keep stdout clean when scripting.
- **`-a` + `2>/dev/null`** is the cleanest “live hosts only” output.
- **`-g` requires two IPs OR CIDR**, not a list of mixed targets.
- **ICMP can be blocked.** Hosts that block ICMP echo will look “unreachable” even when they’re up. Combine with TCP checks (`nc -z`, `nmap -sn -PS22`) for important services.
- **Hosts behind firewalls that drop vs. reject** behave differently — drop = timeout (slow), reject = immediate unreachable.
- **`-i` too low on huge subnets** can flood interfaces and cause its own packet loss. Default 10 ms is usually fine.

-----

## TL;DR — The 5 Commands You’ll Actually Use

```bash
fping -a -g 192.168.1.0/24 2>/dev/null      # live hosts on subnet
fping -q -c 10 host1 host2 host3            # quick latency/loss check
fping -l -D -Q 60 -f hosts.txt              # continuous monitoring w/ summaries
fping -u -f hosts.txt 2>/dev/null           # what's DOWN from my inventory
fping -q -c 3 host && echo UP || echo DOWN  # scriptable health check
```