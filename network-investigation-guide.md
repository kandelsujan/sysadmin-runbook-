# Network Traffic Investigation — A Field Guide for New Sysadmins

You sit in on calls where the team looks at infrastructure traffic — which machines are talking to which, and whether anything is using a port it shouldn't. **Most of this is east-west traffic: hosts inside your own network talking to other hosts inside your own network** (not traffic to the internet). This guide is built around that, and teaches you how to understand what you're looking at and how to investigate it yourself on a Linux host. No prior network-security experience assumed.

> **Why internal traffic needs its own way of thinking:** when something talks to the *internet*, "is this the internet?" is itself a useful alarm. Internal-to-internal, that shortcut is gone — everything is "inside the house," so you can't lean on it. Instead you reason about two things: **what is each host's job (its role)**, and **which parts of the network are allowed to talk to which (segmentation)**. A connection is normal when both hosts' jobs explain it *and* the two network zones are supposed to talk. That idea runs through this whole guide.

**How to read this guide:** Parts 1–3 are the foundation — read them once, in order. Parts 4–7 are what you'll come back to during real investigations. Part 8 covers the dashboards used in the calls, Part 9 is a glossary, and Part 10 is a one-page command card to keep open during calls.

---

## The one idea to hold onto

Almost everything in these calls comes down to a single sentence:

> **Machine A opened a connection to Machine B, on a particular port.**

Your whole job is to answer three questions about that sentence:

1. **Is this connection expected** — do both hosts' *jobs* explain it, and are these two *zones* allowed to talk?
2. **Which side started it**, and does that make sense for their roles?
3. **What program** is responsible for it?

If all three have boring answers, it's fine. If any of them is weird and nobody can explain it, you keep digging. That's it. Everything below is just the vocabulary and tools to answer those three questions quickly.

---

# Part 1 — The mental model

Before any commands, you need a picture in your head. The best analogy is a **phone call**.

| Phone call | Network connection |
|---|---|
| Phone number | **IP address** (which machine) — e.g. `10.0.12.5` |
| Department extension | **Port** (which service on that machine) — e.g. `443` for a website |
| The person who dials | The **client** — the side that *starts* the connection |
| The person who answers | The **server** — the side that was *waiting* for calls |
| A receptionist sitting by the phone | A program **listening** on a port, ready to accept connections |
| A call in progress | An **established** connection |

So when you see `10.0.12.5:54312 → 10.0.30.20:4444`, read it as:
*"Machine `10.0.12.5`, using its temporary extension `54312`, called machine `10.0.30.20` at extension `4444`."*

### 1.1 IP address = which machine

Every machine has an IP. Two kinds matter to you:

- **Internal / private** — your own network. These ranges are reserved for internal use: `10.x.x.x`, `172.16.x.x`–`172.31.x.x`, and `192.168.x.x`. The vast majority of what you'll review lives entirely in here.
- **External / public** — anything else is out on the internet. Less common in your day-to-day, but when it appears it gets extra attention (covered where relevant).

Because nearly everything you look at is internal-to-internal, the question is almost never "internet or not?" — it's "**do these two *specific* internal machines have any business talking?**" To answer that, you need the next two ideas: roles and segments.

### 1.1a Host roles — every machine has a job

A connection only makes sense in the context of what each end *does*. Internal machines have roles, for example:

- **Web / front-end** — serves pages; talks to app servers, not directly to databases.
- **App / middle tier** — runs business logic; talks to web (above it) and databases (below it).
- **Database** — stores data; should be talked *to* by app servers, and should rarely start connections itself.
- **Domain controller / auth** — handles logins (LDAP/Kerberos); lots of machines talk to it.
- **Management / jump host** — where admins log in from to reach other machines.
- **Monitoring / backup / logging** — reaches out to many machines *by design*.

The pattern most apps follow is a tidy chain: **web → app → database.** Each tier talks to its neighbours, not across them. So a *web* server connecting *directly to a database* skips a tier — worth a look. A *database* server **starting** a connection to a web server is backwards — databases mostly answer, they don't dial out.

> The single most useful internal question: **"Does each host's job explain this connection?"** Write the role of both ends next to the flow and it usually answers itself.

### 1.1b Segmentation — which zones may talk

Networks are usually carved into **zones/segments** (often separate VLANs or subnets) that group machines by purpose and sensitivity — e.g. a DMZ for internet-facing servers, an internal app zone, a database zone, a management network, a user/workstation zone, and maybe a locked-down "sensitive" zone (PCI, HR, etc.).

The whole point of segmentation is that **only certain zones are supposed to talk to certain others**, and a firewall between them is meant to enforce it. So a second key question is: **"Are these two zones even allowed to talk?"**

- Workstation zone → database zone directly = unusual (users shouldn't hit DBs raw).
- Management zone → everywhere = expected (that's its job).
- One app zone → a *different, unrelated* app's database = a segmentation concern.
- Anything → the sensitive zone that isn't on the short allow-list = lean in hard.

You won't have the zone map memorized as a newbie — **ask your team for the "what's allowed to talk to what" diagram.** Even a rough one turns half of these calls into a quick lookup.

#### VLANs — the concrete handle on "zone"

In most networks a **VLAN** (a numbered virtual LAN) maps 1:1 to a subnet and to a zone — VLAN 30 *is* the DB zone, VLAN 20 *is* app, and so on. So the VLAN number is often the cleanest way to answer "zone fit": when the call's dashboard shows a source VLAN and destination VLAN, cross-zone violations are obvious at a glance (VLAN 50 → VLAN 30 = users hitting databases directly).

The nuance that catches people out:

- **Different VLANs → traffic is *routed*** through an L3 device, and (ideally) your **firewall** sees it. This is the traffic your zone rules actually govern.
- **Same VLAN → traffic is *switched* at layer 2 and never reaches the router or firewall at all.** Your firewall rules do **nothing** for host-to-host traffic inside a single VLAN. This is why an attacker who lands on one host can often move sideways to its VLAN neighbours freely, with no firewall log to show for it. So "are these two hosts in the same VLAN?" tells you *whether to even expect a firewall record* — a key triage question for east-west.

Also worth a flag: a regular server that is **aware of multiple VLANs** (carries 802.1Q tags or has VLAN subinterfaces) is unusual — normally only switches, hypervisors, and firewalls do that. A server bridging VLANs is the dual-homed problem (§3.7) in another form, and a host appearing on a VLAN it shouldn't be on can mean a misconfiguration or a VLAN-hopping attempt.

**How you actually see the VLAN:** a normal host on an "access port" can't see its own VLAN — the switch tags/untags invisibly. You get it from: the **host only if it tags traffic itself** (`ip -d link show` reveals subinterfaces like `eth0.30@eth0 … vlan id 30`); a **capture on a trunk link** (`tcpdump -e -nni eth0 vlan` prints the tag); or — most often — the **switch / IPAM / CMDB**, which is the network team's data and a big reason VLAN info lives on these calls.

### 1.2 Port = which service

A port is a numbered door on a machine. By convention, common services sit on fixed port numbers so clients know where to "call":

- Port **22** → SSH (remote login)
- Port **443** → HTTPS (secure websites)
- Port **53** → DNS (looking up names)

Ports **0–1023** are the "well-known" ports for standard services. Ports above that get used as **temporary (ephemeral) ports** by clients when they dial out — your machine grabs a random high number like `54312` just for the duration of one call, then throws it away.

**This is a key tell for direction:** if your machine's side of a connection is a high random port and the *other* side is a low well-known port, your machine is almost certainly the **client** (it dialed out). If your machine's side is a low well-known port, your machine is the **server** (it answered a call).

### 1.3 Listening vs established

Two states you'll see constantly:

- **LISTEN** — a program is sitting by a port waiting for connections, like a receptionist. A web server *listens* on 443. No one is connected yet; it's just open for business.
- **ESTAB** (established) — an actual live connection between two machines. A call is in progress.

When you list connections on a host, you'll see a mix: some LISTEN lines (services this machine offers) and some ESTAB lines (calls happening right now).

### 1.4 Who started it? (inbound vs outbound)

This matters more than almost anything else, so here's how it actually works under the hood, kept simple.

To start a TCP connection, the client sends a special first packet called a **SYN** ("let's talk"). The server replies with **SYN-ACK** ("sure, go ahead"), and the client sends **ACK** ("great"). That's the *three-way handshake*. The important part:

> **Whoever sends the first SYN is the one who started the connection.**

- **Inbound** = someone else started a connection *to* your machine. Normal for servers (a database gets connected to by app servers all day).
- **Outbound** = your machine started a connection *to* someone else. Normal for clients (an app server dialing its database). The classic internet red flag is a server reaching out to the internet for no reason — but **internally, direction is just as telling**: a *database* server **initiating** a connection to other machines is backwards (databases mostly answer, not dial). A server in one zone reaching *into* the management network, or a workstation **initiating** to lots of servers, are the kinds of "wrong-way" connections that matter east-west.

You can read direction two ways: the quick heuristic from §1.2 (which side has the low port), or definitively by watching the handshake with `tcpdump` (Part 3). Pair direction with roles: *"which machine dialed, and does its job involve dialing that kind of machine?"*

### 1.5 TCP vs UDP (in 20 seconds)

- **TCP** — reliable, connection-based (does the handshake above). Most things: web, SSH, databases, email.
- **UDP** — fire-and-forget, no handshake. DNS, NTP (time), some streaming/VoIP.

You don't need more than that to start. Just know that "no handshake to watch" with UDP means you lean on *what port / what process* instead of *who sent SYN*.

---

# Part 2 — Your toolkit

These are the standard tools on almost any Linux box. You don't need all of them at once. **If you learn only three, learn `ss`, `lsof`, and `ps`** — together they answer "what's connected and what program is responsible."

| Tool | One-line purpose | The question it answers |
|---|---|---|
| `ss` | List network connections & listening ports | *What is this machine talking to right now?* |
| `lsof` | List open files/sockets **with the program** | *Which program owns this connection?* |
| `ps` | Inspect a running process | *What is that program, and who started it?* |
| `tcpdump` | Capture live packets | *Who started this, and what's actually on the wire?* |
| `dig` | Look up DNS names | *What name does this IP have / where does a name point?* |
| `whois` | Look up who owns an IP/domain | *Whose machine is this external address?* |
| `journalctl` / logs | Read system & service logs | *What happened earlier / is this service complaining?* |
| `ip route get` / `traceroute` / `mtr` | Show the path to a destination | *Which way does traffic to this host actually go?* |
| `ip -br addr` / `ip route` | Show a host's interfaces & routes | *Is this host bridging two zones / using an odd gateway?* |

Install notes: `ss`, `ps`, and `ip` are always present. `lsof`, `tcpdump`, `dig` (in `dnsutils`/`bind-utils`), `whois`, `traceroute`, and `mtr` may need installing (`apt install` / `dnf install`). `tcpdump` needs root.

---

# Part 3 — Reading the output (the important part)

Knowing the command is easy. **Reading what it prints is the actual skill.** Here is each tool with real output, every column explained, and what to look for.

Throughout, I'll use one running example of something bad so it threads together: a **web server** `10.0.12.5` that has a sneaky connection to `10.0.30.20` — a host over in the **database zone** — on port `4444`. A web server has no business reaching into the DB zone, on that port, with that tool. That's a classic internal lateral-movement picture.

### 3.1 `ss` — what's connected right now

Most useful form:
```
ss -tunap
```
Read the flags as a sentence: **t**cp + **u**dp, **n**umeric (don't translate numbers to names — faster and clearer), **a**ll (listening *and* established), **p**rocess (show the program). To see only what's *listening* (services this box offers), use `ss -tlnp`.

Example output:
```
Netid State  Recv-Q Send-Q  Local Address:Port     Peer Address:Port      Process
tcp   LISTEN 0      128     0.0.0.0:22             0.0.0.0:*             users:(("sshd",pid=812))
tcp   LISTEN 0      511     0.0.0.0:443            0.0.0.0:*             users:(("nginx",pid=990))
tcp   ESTAB  0      0       10.0.12.5:443          10.0.12.40:51234     users:(("nginx",pid=990))
tcp   ESTAB  0      0       10.0.12.5:54312        10.0.30.20:4444  users:(("nc",pid=4821))
```

Column by column:
- **State** — `LISTEN` (waiting for calls) or `ESTAB` (live connection). See §1.3.
- **Recv-Q / Send-Q** — data queued up, waiting to be read/sent. Almost always `0`. Big numbers mean a backlog (usually a performance issue, not security).
- **Local Address:Port** — **this machine's** side. `0.0.0.0` on a LISTEN line means "listening on all network interfaces."
- **Peer Address:Port** — the **other** machine's side. `0.0.0.0:*` on a LISTEN line means "anyone may connect."
- **Process** — the program and its PID (process ID) responsible for the socket. *This is the gold.*

Now read the four lines like a human:
- Line 1: `sshd` listening on 22 — this box accepts SSH logins. Normal.
- Line 2: `nginx` listening on 443 — it's a web server. Normal.
- Line 3: `nginx` has a live connection from `10.0.12.40` (an internal machine) to our port 443 — someone internal is browsing our website. **Normal** (low local port = we're the server, they called us).
- **Line 4: this is the problem.** Our web server, on a high random port `54312`, started a live connection *to* `10.0.30.20` — a machine in the **database zone** — on port `4444`, and the program responsible is `nc` (netcat). A web server has no business reaching into the DB zone at all, never mind on a weird port with netcat. High local port = **we** started it. Wrong role, wrong zone, wrong tool.

> **What to look for in `ss`:** ESTAB lines where *we* started the connection (high local port) to a host whose **zone/role doesn't fit ours**, and the Process is something that isn't a normal service (`nc`, `python`, `bash`, a random name).

### 3.2 `lsof` — which program owns a connection

`lsof` lists open files — and a network socket counts as a kind of file. The catch: by default `lsof` lists *every* open file on the system (regular files, directories, pipes, local sockets, devices, the lot), which is thousands of lines. The `-i` flag **filters that down to just network sockets** — that's why you use it. Use:
```
lsof -i -P -n
```
(`-i` = show only network sockets, `-P` = don't rename ports, `-n` = don't rename IPs — the last two keep output fast and literal.)

> **Naming gotcha:** the "Internet" in "Internet socket" is a technical family name (IP-based sockets), **not** "the public internet." `lsof -i` shows your internal host-to-host connections perfectly well — they're "Internet sockets" in this sense even though they never leave your network.

You can narrow it further: `lsof -iTCP` (TCP only), `lsof -iTCP -sTCP:ESTABLISHED` (live TCP only), `lsof -i :22` (one port), `lsof -i @10.0.30.20` (one host).

```
COMMAND  PID  USER  FD   TYPE  NODE NAME
sshd     812  root  3u   IPv4  TCP  *:22 (LISTEN)
nginx    990  www   6u   IPv4  TCP  10.0.12.5:443->10.0.12.40:51234 (ESTABLISHED)
nc       4821 root  3u   IPv4  TCP  10.0.12.5:54312->10.0.30.20:4444 (ESTABLISHED)
```

- **COMMAND** — the program name.
- **PID** — its process ID (you'll use this with `ps` next).
- **USER** — which account runs it. *A connection running as `root` deserves extra scrutiny.*
- **NAME** — the connection itself. The `->` arrow shows direction: `local->remote`.

The bottom line is the same villain: `nc`, running as `root`, with a connection going *to* `10.0.30.20:4444` over in the DB zone. `lsof` makes the "which user / which program" part very explicit, which is why it pairs so well with `ss`.

> **Tip:** to ask "who is using port 4444 right now?" directly: `lsof -i :4444`. To ask "who's talking to that IP?": `lsof -i @10.0.30.20`.

### 3.3 `ps` — what is that program, and who started it?

Now you have a PID (`4821`). Find out what it really is:
```
ps -fp 4821
```
```
UID   PID  PPID  C STIME TTY   TIME CMD
root  4821 4400  0 02:00 ?     00:00 nc 10.0.30.20 4444
```

- **CMD** — the full command line. Here it's literally netcat connecting to the bad IP on 4444. Damning.
- **PPID** — the **parent** process ID: *what launched this?* Trace it upward: `ps -fp 4400` tells you who started the netcat. If the parent is your web server or a web process, that points to a compromised website (a "web shell"). Following the parent chain is how you find the root cause rather than just the symptom.

Two more quick checks once you have a PID:
```
ls -l /proc/4821/exe     # the real path of the running binary
ls -l /proc/4821/cwd     # the folder it's running from
```
> **Red flag:** the binary lives in `/tmp`, `/dev/shm`, or someone's home directory, or has a random-looking name. Legit services run from places like `/usr/sbin` or `/usr/bin`.

### 3.4 `tcpdump` — prove direction and see what's on the wire

When you need to *prove* who started a connection, or see the actual traffic, capture packets. **Needs root.**

```
tcpdump -nni eth0 host 10.0.30.20
```
- `-nn` = don't translate IPs or ports to names. `-i eth0` = which network interface (use `ip addr` to find yours, often `eth0`/`ens3`). `host X` = only show traffic to/from X.

```
02:00:03.123456 IP 10.0.12.5.54312 > 10.0.30.20.4444: Flags [S], seq 100
02:00:03.171002 IP 10.0.30.20.4444 > 10.0.12.5.54312: Flags [S.], seq 800, ack 101
02:00:03.171050 IP 10.0.12.5.54312 > 10.0.30.20.4444: Flags [.], ack 801
```

Reading a line: `timestamp  IP  source.port > destination.port: Flags [...]`. The `Flags` field is the handshake from §1.4:
- `[S]` = SYN — *starting* a connection.
- `[S.]` = SYN-ACK — the reply.
- `[.]` = ACK — acknowledgement.

The very first packet is `[S]` going **from `10.0.12.5`** (the web server). **That proves the web server started it** — the DB-zone host didn't reach in to us; we reached into it. For internal lateral movement, that "which side dialed" answer is exactly what tells you whether a host is the *aggressor* or the *victim*.

Handy filters:
```
tcpdump -nni eth0 port 4444                              # only that port
tcpdump -nni eth0 'dst port not (80 or 443 or 53)'      # ignore normal web/DNS, show the rest
tcpdump -nni eth0 -w capture.pcap -c 2000               # save 2000 packets to a file for later
```
The `-w file.pcap` form saves a capture you can open later in Wireshark for a friendlier view — useful to hand to a senior teammate.

### 3.5 `dig` (and `whois`) — what *is* that host?

You have an IP and need to know what machine it is and what its job is.

**For an internal IP** (your usual case), reverse-DNS usually gives you a hostname that encodes the role, and your inventory/CMDB fills in the rest:
```
dig +short -x 10.0.30.20      # reverse lookup: IP -> hostname
```
```
db-prod-03.dbzone.example.internal.
```
That name tells the story: it's a **production database** in the **DB zone**. Now the running example is unambiguous — our *web* server reached a *production database* host directly, on port 4444. Cross-reference the name against your CMDB/inventory to confirm the role, owner, and which zone it lives in.

**For the occasional external IP**, `whois` tells you who owns it:
```
whois 203.0.113.45 | grep -iE 'netname|orgname|country'
```
> **Red flag (external):** owner is Tor, a VPN/anonymizer, "bulletproof" hosting, or a country you never deal with, with no friendly name. **Benign:** a known vendor, your cloud provider, or an update mirror.

You can also go forward — `dig db-prod-03.example.internal` — to confirm what a hostname in a log actually resolves to.

### 3.6 Logs — what happened before you got here

`ss`/`lsof` show *now*. Logs show *history*.
```
journalctl -u nginx --since "1 hour ago"     # logs for a specific service
journalctl --since "02:00" --until "02:10"   # everything in a time window
last                                          # recent successful logins
journalctl -u ssh --since today               # SSH login activity
```
> Use these to answer: *Did this service get attacked or do something odd right before the bad connection appeared? Did someone log in unexpectedly?* On older systems, the same info lives in `/var/log/` (`/var/log/auth.log`, `/var/log/syslog`).

### 3.7 Path — which way does the traffic actually go?

Endpoints tell you *who* is talking; sometimes you also need *how the packets get there*. This matters most for **verifying segmentation** (does cross-zone traffic really pass through the firewall you think?), catching **dual-homed hosts** that bridge two zones, and spotting **relays/pivots** in lateral movement.

**Predict the path without sending anything — `ip route get`.** This asks the kernel "if I send to X, which interface and gateway do I use?"
```
ip route get 10.0.30.20
```
```
10.0.30.20 via 10.0.12.1 dev eth0 src 10.0.12.5
```
Read it as: to reach the DB-zone host, this box goes **via gateway `10.0.12.1`, out interface `eth0`.** *Red flag:* an unexpected gateway or a second interface you didn't know the host had — that can mean traffic is taking a path that skips inspection.

**See the actual hops — `traceroute` / `mtr`.**
```
traceroute -n 10.0.30.20      # list the routers between here and there
mtr -n 10.0.30.20             # same, but live/continuous
```
Each line is one hop (one router) on the way. *Caveat:* internal routers and firewalls often don't reply, so you'll see `* * *` gaps — that's normal internally and doesn't mean the path is broken. What's useful is the **shape**: does cross-zone traffic pass through the hop you expect (your firewall), or does it reach the other zone in a single hop (suggesting the two zones are bridged directly, bypassing the firewall)?

**Catch a dual-homed / bridging host — `ip -br addr`.** A machine with legs in two zones quietly defeats segmentation.
```
ip -br addr
```
```
eth0   UP   10.0.12.5/24
eth1   UP   10.0.30.7/24      <-- a second leg, in the DB zone
```
*Red flag:* a host you didn't expect to be multi-homed has an interface in another zone. That host can shuttle traffic across a boundary your firewall never sees. (`ip route` and `ip rule` will also reveal extra or unusual routes — e.g. a rogue second default gateway.)

**Confirm the control is in the path.** The decisive segmentation check: take a cross-zone flow you found and look for it in the **firewall logs**. If the flow clearly happened but the firewall has no record of it, the traffic bypassed the firewall — investigate how (VLAN misconfig, static route, or a dual-homed host like above). One quick gut-check first: if the two hosts are in the **same VLAN** (§1.1b), the firewall *never* sees them — that traffic is switched, not routed — so a missing firewall log there is expected, not a finding.

> Quick tie-in: those `S0` "half-connections" that look like scanning (Part 7-E) are sometimes just **asymmetric routing** — the request and reply take different paths, so your sensor only sees one side. Checking the path is how you tell a real scan from a routing quirk.

---

# Part 4 — What "normal" looks like

You can't spot weird until you know normal. For east-west traffic, "normal" comes from three things: the host roles match, the zones are allowed to talk, and the connection looks like what the host's **peers** do. Plus the usual port knowledge.

### 4.0 The internal baseline — roles, zones, and peers

Before the port list, internalize these three checks — they decide most internal cases:

- **Role fit.** Does each end's job explain the connection? *App server → database on 5432* fits. *Database → workstation* does not. (See §1.1a.)
- **Zone fit.** Are these two segments supposed to talk at all? *Management → anywhere* fits. *Workstation zone → database zone direct* usually doesn't. (See §1.1b.)
- **Peer fit (the most powerful trick).** Compare a host to its **siblings** — machines with the same role. If `web-01` makes a connection that `web-02`, `web-03`, … never make, *that single odd host* is what to investigate. Identical machines should have near-identical traffic; the outlier is the story.

> When a flow looks strange, ask: *"Do this host's peers do the same thing?"* If yes → probably a normal pattern you didn't know about. If no → focus there.

### 4.1 Common ports (memorize the top handful)

These are the internal services you'll see between hosts constantly:

| Port | Service | Who normally talks it (internal) |
|---|---|---|
| 22 | SSH | Admins/jump hosts → servers; automation |
| 53 | DNS | Every host → your DNS servers |
| 80 / 443 | HTTP / HTTPS | Clients/LBs → web & app tiers; service-to-service APIs |
| 389 / 636 | LDAP / LDAPS | Servers/workstations → domain controllers (logins) |
| 88 | Kerberos | Everything → domain controllers (auth) |
| 445 | SMB | File servers; **also the #1 lateral-movement port** — watch server↔server SMB |
| 3389 | RDP | Admins → Windows servers; **watch unexpected sources** |
| 5985 / 5986 | WinRM | Windows remote management/automation |
| 123 | NTP | Every host → time servers |
| 161 / 162 | SNMP | Monitoring → network gear/servers |
| 25 / 587 | SMTP | App servers → mail relay |
| 3306 / 5432 / 1433 / 1521 | MySQL / Postgres / MSSQL / Oracle | **App tier → DB tier only** (web tier or workstations hitting these = look) |
| 6379 / 27017 / 9200 | Redis / Mongo / Elasticsearch | App tier → data store (often *no password by default* — exposure is bad) |

### 4.2 Ports / patterns that should make you look twice (internal)

- **Admin/auth protocols between two *servers* that don't usually do that** — SSH (22), RDP (3389), WinRM (5985/6), SMB (445). Server-to-server lateral movement loves these.
- **4444** — default Metasploit port. Rarely innocent, internal or not.
- **23 (Telnet), 21 (FTP)** — old, *unencrypted*. Passwords travel in plain text.
- **A high random port as the destination** with no known service behind it — could be a custom backdoor.
- **A tier talking past its neighbour** — web tier reaching a DB directly, or anything reaching across into a sensitive/management zone.

### 4.3 Scary-looking but usually fine

Don't raise the alarm without checking — most internal "alerts" are one of these:

- **Monitoring / backup / config-management agents** (Nagios, Zabbix, Prometheus, Puppet/Chef/Salt, your EDR/AV) — these connect to **many** hosts *on a schedule by design*. One central box touching everything is usually one of these. (Regularity alone isn't malware — see Part 7-D.)
- **Load-balancer / health-check probes** — tiny, frequent, repetitive hits to an app port.
- **Domain controllers** being talked to by almost everything on 88/389/445 — that's just authentication.
- **Clustering / replication** — database replicas, app cluster members, and storage nodes chatter among themselves on their own ports.
- **A change you didn't know about** — a new deploy, a scaled-up pool, a migration. **Always check for a change ticket** before assuming the worst.
- **`169.254.169.254`** — cloud metadata service; normal *from* a cloud VM.

---

# Part 5 — Red flags (quick scan)

Any one of these alone might be innocent. **Several together = investigate.** Listed internal-first.

- A host talking to an internal machine it has **never** contacted before, and whose **peers don't** make that connection either.
- A connection whose **two roles don't fit** (e.g. database **initiating** outbound; web tier hitting a DB directly).
- Traffic **crossing a segment boundary** that shouldn't be crossed (into the management or a sensitive zone; workstation → DB direct).
- **Admin/auth protocols** (SSH, RDP, SMB, WinRM) appearing **server-to-server** where they don't normally.
- **One machine touching many others** on the same port (internal scanning / lateral movement — Part 7-E).
- Connections owned by **interactive tools** — `nc`, `python`, `bash`, `powershell` — instead of the host's real services.
- A program running from **`/tmp`, `/dev/shm`, or a home folder**, or with a random name.
- **Regular, identical, small** connections to one destination that isn't a known agent's server (beaconing — Part 7-D).
- **Large transfers** between hosts that have no reason to move bulk data, especially **off-hours**.
- **Unencrypted** protocols (Telnet, FTP, plain HTTP) carrying logins or data.
- *(When external does appear)* a server **initiating** to the internet, or a connection to a raw IP / Tor / VPN endpoint.

---

# Part 6 — The investigation loop (use this every time)

When anything looks off, run the same five steps. This is the whole method; the scenarios in Part 7 are just this loop with specifics.

1. **SEE it.** Write down the flow: *source IP, destination IP, port.* (From the call dashboard, a log, or `ss` on the box.)
2. **ME or THEM?** Which side started it — who sent the first SYN (§1.4)? Quick check: which side has the low port. Definitive check: `tcpdump`.
3. **NORMAL?** Run the three internal checks: **role fit** (do both hosts' jobs explain it?), **zone fit** (are these segments allowed to talk?), **peer fit** (do this host's siblings make the same connection?). Cross-check the port against §4. If all three fit → almost always benign.
4. **WHO / WHAT.** On the source host, find the **process** (`ss -tunap` → PID → `ps -fp <pid>` → check the parent). Identify the **other host's role** (your CMDB/inventory; `dig -x <ip>` for its name). Check change tickets.
5. **DECIDE.**
   - *Benign* → note it, and add it to your team's "known-weird-but-fine" list so it doesn't get re-investigated next call.
   - *Watch* → unclear; keep an eye on it / capture more data.
   - *Escalate* → roles/zones don't fit + peers don't do it + odd process + no ticket (e.g. one server using SSH/SMB to reach many others). Don't sit on it; hand it to your senior/security with the facts you gathered.

Keep a tiny note for each finding: **source (role), dest (role), port, direction, process, peers-do-same? (y/n), zone-crossing? , business reason (or "none"), decision.** That note is exactly what your senior needs if you escalate.

---

# Part 7 — Scenario runbooks

Each is the Part-6 loop applied to a specific situation, with the commands and what you'll see.

### A) "This host is talking to an internal machine it's never talked to before" — the bread-and-butter case

A brand-new edge appears in the host-to-host map: two internal machines with no prior history of talking.

1. **Confirm it's real.** On the source: `ss -tunap | grep <dest-ip>`. An `ESTAB` line = it's live (not a sensor glitch).
2. **Name both ends and their roles.** Look them up in your inventory/CMDB; `dig +short -x <ip>` gives the hostname, which often encodes the role (`db-prod-03`, `web-stg-01`). Write the **role of each side** next to the flow.
3. **Apply the three internal checks** (this is where it's usually decided):
   - **Role fit** — does each job explain it? *app → db on 5432* fits; *db → workstation* doesn't.
   - **Zone fit** — are these segments allowed to talk? (Use your zone map.)
   - **Peer fit** — do the source's *siblings* make the same connection? `ss`/flow data on `web-02`, `web-03`. **If only this one host does it, that's your lead.**
4. **Check the port** against both roles (§4). Blank/odd port = lean in.
5. **Find the process** on the source: `ss -tunap` → PID → `ps -fp <pid>` → follow the parent. *Red flag:* `nc`/`python`/`bash`/`powershell` rather than a real service.
6. **Check for a change ticket.** *Benign* if a deploy/new service explains it (and peers will usually show it too). **Escalate** if: roles/zones don't fit + peers don't do it + odd process + no ticket.
7. **If it crosses zones, verify the path (§3.7).** `ip route get <dest>` and a glance at the firewall logs: did this cross-zone flow actually pass through the firewall? If it crossed zones but the firewall never saw it, you've also found a **segmentation gap** (rogue route or a dual-homed host) — flag that separately, it's a finding on its own.

### B) "Traffic on an unexpected port" (between two internal hosts)

1. **Who owns the port?** On the source: `lsof -i :<port>` (or `ss -tunap | grep :<port>`). Note the PID.
2. **Is the binary legit?** `ls -l /proc/<pid>/exe`. *Red flag:* runs from `/tmp`, `/dev/shm`, a home dir, or has a random name. *Benign:* the real app binary from `/usr/...`.
3. **Who launched it?** `ps -fp <pid>` and follow the **PPID**. *Red flag:* spawned by a web server or a shell (web-shell / post-exploitation pattern).
4. **Is it a known-but-undocumented service?** Lots of internal "odd ports" are just an app on a custom port (e.g. an internal API on 8081). Confirm the source's **peers** use the same port → if so, it's normal; verify with the owner and **add it to the known-weird list.** A lone host on a weird port, owned by a non-service binary → **escalate.**

### C) "Large transfer between two internal hosts"

Internally this is usually backups, replication, or a migration — but it can also be **staging data before it's stolen**.

1. **See the size and direction.** From the call's flow view (bytes column), or on the host `iftop -nNP` (live bandwidth per connection).
2. **Do the roles justify bulk data?** *Backup client → backup server*, *DB primary → replica*: yes. *A random app server → a workstation*: no. *Red flag:* big transfer between hosts whose roles never move bulk data, especially **off-hours**.
3. **Peer check.** Do sibling hosts run the same transfer on the same schedule? A nightly job shows up across the whole pool; a *single* host doing a big push is the outlier.
4. **What's doing it?** `ss -tunap` → PID → `ps`. Look for an archiving step nearby (`zip`, `tar`, `rclone`, `scp`).
5. If unexplained, **capture evidence** — `tcpdump -nni eth0 host <dest> -w transfer.pcap -c 5000` — and **escalate** (possible data staging/exfil prep). Keep the file.

### D) "Small, regular connections to the same place" (beaconing)

Malware "checks in" with whatever controls it on a steady timer. Internally, the controller might be *another compromised internal host*, not the internet — so don't dismiss this just because the destination is in your own ranges.

1. **Look at the timing.** Pull repeated connections to the destination and eyeball the gaps:
   ```
   02:00:03  web-01 -> 10.0.30.9:8080   512 bytes
   02:01:03  web-01 -> 10.0.30.9:8080   512 bytes
   02:02:04  web-01 -> 10.0.30.9:8080   516 bytes
   ```
   *Red flag:* near-constant interval (~60s here) and near-constant size, for hours. Real human/app traffic is bursty and irregular.
2. **Rule out legit agents FIRST.** Monitoring, backup, and config tools (Zabbix/Nagios/Puppet/EDR) beacon *by design* — but to **their own management server**, and **all their peers do it too**. *Benign* if the destination is that known management host and the whole pool behaves identically. *Red flag* if it's a host that isn't an agent server, or **only this one source** beacons there.
3. **Find the process** (`ss -tunap` → `ps`) and identify the destination host's role. **Escalate** if a non-agent process beacons to a host that has no business being a control point.

### E) "One host reaching into lots of others" — lateral movement (the main internal threat)

This is the big one for east-west review. After an attacker lands on one internal machine, they **fan out** — probing or logging into other internal hosts. That shows up as one source touching many destinations.

1. **Spot the pattern.** One source → many destinations on the same port (a **sweep**, hunting for a service), or one source → many ports on one destination (a **port scan**). On the flow view these often show as lots of *failed/unanswered* attempts (tiny bytes, no real session).
2. **Measure the spread.** How many distinct destinations did this one source touch in a short window? Ten, fifty, the whole subnet? Breadth is the alarm.
3. **What port?** Especially worrying on **admin/auth protocols** — SSH (22), SMB (445), RDP (3389), WinRM (5985/6), WMI. An attacker spreading uses exactly these.
4. **Is it sanctioned?** Your team likely runs a vulnerability scanner / asset-discovery tool on a schedule from a known box. *Benign* if it's that approved scanner in its window. *Red flag* if the source is a **workstation, app server, or anything with no reason to scan** — those don't sweep the network.
5. **Find the tool** on the source (`ss`, `ps`, check `/proc/<pid>/exe`) — `nmap`, `masscan`, `crackmapexec`, PowerShell, or a custom script. Unsanctioned internal sweeping = **escalate immediately**; this is what a compromise spreading looks like.

### F) "Admin / auth protocol showing up where it shouldn't" (server-to-server)

A focused version of lateral movement worth its own check, because it's high-signal.

1. **Notice the pattern.** SSH, RDP, SMB (445), or WinRM appearing **between two servers** that don't normally use it that way — e.g. one app server suddenly SSHing to several others, or SMB connections fanning out from a host that isn't a file server.
2. **Direction & source.** Who initiated, and is that host an admin/jump host (allowed) or a regular server (not)? *Benign:* your jump host reaching servers for admin. *Red flag:* a non-admin server initiating admin protocols to peers.
3. **Peer & ticket check.** Do sibling hosts do this? Is there a maintenance ticket? No to both + non-admin source = **escalate** as likely lateral movement / credential abuse.

### G) "Weird DNS activity"

DNS is allowed almost everywhere, so it gets abused to tunnel data. Internally, watch for a host hammering your DNS servers oddly.

1. **Look at the queries.** *Red flag:* long, random-looking names (e.g. `aGVsbG8gd29ybGQ.x9f2k1.evil.com`), lots of `TXT`-type lookups, and **many unique sub-names under one domain**. Normal lookups are short and ask for an `A` record.
2. **Check the volume** — a steady flood of unique sub-names to one domain is the tunneling signature.
3. **Which resolver?** *Red flag:* a host doing DNS directly to something that isn't your approved internal resolver, or DNS on a nonstandard port.
4. **Find the process** (`lsof -i :53`) and **escalate**; consider blocking the parent domain.

### H) "Plain-text protocol where it shouldn't be"

1. **Identify it.** Telnet (23), FTP (21), or plain HTTP (80) used for admin or data movement between internal hosts.
2. **Confirm it breaks policy** — this path should use the encrypted equivalent (SSH / SFTP / HTTPS).
3. **Assess exposure.** A quick `tcpdump -nni eth0 -A port 23 -c 50` can literally show credentials in clear text on the wire. Even between "trusted" internal hosts that's a problem — anyone who compromises the path or a switch can read them. If logins/sensitive data were exposed, treat as a **possible credential leak** and escalate; otherwise flag the owner to move to the encrypted version.

---

# Part 8 — A note on "flow data" tools (for the calls)

In the calls, the team probably isn't logging into each box — they're looking at a **central view** of traffic. That view is built from *flow records*: summaries of "A talked to B on port P, this many bytes." You don't need to operate these tools as a newbie, but it helps to recognize the names so you can follow along:

- **NetFlow / IPFIX** — the network devices themselves report flow summaries. Tools like `nfdump` query them.
- **Zeek** (formerly Bro) — a sensor that watches traffic and writes rich logs (its `conn.log` is the master list of connections).
- **An NDR / SIEM dashboard** — a commercial product that presents all of this with search and alerts.

The mental model is identical to everything above — *source, destination, port, direction, bytes.* When something on that central view looks off, **your job is to go to the actual host and run the Part-3 tools to confirm it.** The dashboard says "something happened"; `ss`/`lsof`/`ps`/`tcpdump` tell you *what and why*.

---

# Part 9 — Glossary

- **Beaconing** — malware "checking in" with its controller at regular intervals.
- **Asymmetric routing** — when a request and its reply travel different paths; can make a sensor see only one side of a conversation.
- **Client** — the side that *starts* a connection (the dialer).
- **C2 / Command-and-Control** — the attacker's server that compromised machines phone home to.
- **DNS** — the system that turns names (`example.com`) into IPs (`93.184.x.x`).
- **Dual-homed host** — a machine with interfaces in two networks/zones at once; it can bridge traffic across a boundary the firewall never sees (a segmentation risk).
- **East-west traffic** — connections *between internal hosts*, inside your network (vs "north-south," traffic to/from the internet). This is most of what you review.
- **Egress** — traffic *leaving* your network (outbound).
- **Ephemeral port** — a temporary high-numbered port a client uses for one outbound connection.
- **Established (ESTAB)** — a live, in-progress connection.
- **Exfiltration** — stealing data out of the network.
- **Flow** — a one-line summary of a connection (who, who, port, bytes).
- **Gateway** — the router a host sends traffic through to reach other networks; an unexpected gateway can mean traffic skips inspection.
- **Handshake** — the SYN / SYN-ACK / ACK exchange that opens a TCP connection.
- **Hop** — one router along the path between two hosts; `traceroute` lists the hops.
- **Host** — any machine on the network.
- **Inbound** — a connection started *by someone else, toward your machine*.
- **Lateral movement** — an attacker spreading from one internal machine to others. The main thing east-west review is looking for.
- **Listening (LISTEN)** — a program waiting to accept connections on a port.
- **Outbound** — a connection your machine *starts* toward someone else.
- **Peer / baseline** — other hosts with the same role; comparing a host to its peers is the fastest way to spot an outlier.
- **PID / PPID** — Process ID / its Parent's Process ID.
- **Port** — a numbered "door" identifying a service on a machine.
- **Role** — a host's job (web, app, database, domain controller, jump host, monitoring…). Connections should fit both ends' roles.
- **Segmentation / zone** — dividing the network into groups (DMZ, app, DB, management, user, sensitive) where only certain zones may talk to certain others.
- **Server** — the side that *waits for and accepts* connections.
- **Socket** — one end of a network connection (an IP+port pair) on a machine.
- **SYN** — the first packet that starts a TCP connection; whoever sends it initiated the connection.
- **TCP / UDP** — the two main transport protocols (reliable+handshake / fire-and-forget).
- **Trunk vs access port** — a switch port that carries *many* VLANs (trunk, used between switches/firewalls/hypervisors) vs one that carries a single VLAN to one host (access). A regular server on a trunk is unusual.
- **VLAN** — a numbered virtual LAN that segments a switch into separate networks; usually maps 1:1 to a subnet and a zone. Same-VLAN traffic is switched (skips the firewall); cross-VLAN traffic is routed (the firewall can see it).
- **VLAN hopping** — an attack/misconfiguration that lets a host reach a VLAN it shouldn't.

---

# Part 10 — One-page command card

Keep this open during calls.

```
WHAT'S CONNECTED RIGHT NOW
  ss -tunap                      all TCP/UDP, listening + established, with process
  ss -tlnp                       only what this host is LISTENING on
  ss -tunap | grep <ip>          connections to/from a specific machine
  ss -tunap | grep :<port>       connections on a specific port

WHICH PROGRAM OWNS IT
  lsof -i -P -n                  all network connections + program + user
  lsof -i :<port>                who is using this port
  lsof -i @<ip>                  who is talking to this IP

INSPECT THE PROGRAM (after you have a PID)
  ps -fp <pid>                   full command line of the process
  ps -fp <ppid>                  the parent (who launched it) — follow the chain
  ls -l /proc/<pid>/exe          real path of the binary  (red flag: /tmp, /dev/shm, home)

PROVE DIRECTION / SEE THE TRAFFIC  (needs root)
  tcpdump -nni eth0 host <ip>            traffic to/from an IP; first [S] = who started it
  tcpdump -nni eth0 port <port>         traffic on a port
  tcpdump -nni eth0 host <ip> -w cap.pcap -c 5000   save for later / Wireshark

IDENTIFY A HOST / ADDRESS
  dig +short -x <ip>             reverse lookup: IP -> hostname (often shows the role)
  dig <name>                     forward lookup: name -> IP
  whois <ip>                     ownership (mainly for the occasional external IP)

HISTORY / LOGS
  journalctl -u <service> --since "1 hour ago"
  last                           recent logins

WHICH PATH DOES TRAFFIC TAKE
  ip route get <ip>              predict interface + gateway used to reach <ip>
  traceroute -n <ip>            actual hops (internal: * * * gaps are normal)
  ip -br addr                    host's interfaces (spot a leg in another zone = bridge)
  ip -d link show                show VLAN subinterfaces (eth0.30 = host is VLAN-aware)
  tcpdump -e -nni eth0 vlan      show 802.1Q VLAN tags (only on a trunk link)
  ip route ; ip rule             routing table & policy (spot a rogue gateway/route)
  # same VLAN  = switched, firewall never sees it
  # cross VLAN = routed, firewall should have a log  -> check it

LIVE BANDWIDTH (find big transfers)
  iftop -nNP                     bandwidth per connection
  nethogs                        bandwidth per process

THE LOOP, EVERY TIME:
  1 SEE      source IP, dest IP, port
  2 ME/THEM? who sent first SYN (low port = server; high port = client)
  3 NORMAL?  role fit (both jobs explain it?) + zone fit (allowed to talk?) + peer fit (siblings do it too?)
  4 WHO/WHAT process on source (ss -> ps -> parent) + role of the other host (dig -x / CMDB) + change ticket?
  5 DECIDE   benign (note it) / watch / escalate
             escalate = roles+zones don't fit + peers don't do it + odd process + no ticket
             (classic: one server using SSH/SMB/RDP to reach many others = lateral movement)
```

---

*Last thing: nobody expects you to have all of this memorized. The point isn't to know everything — it's to run the same five-step loop calmly every time, write down what you find, and escalate with facts when something doesn't add up. That's exactly what a good investigation looks like.*
