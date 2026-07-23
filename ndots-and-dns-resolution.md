# `ndots` and the Stub Resolver: A Practical Reference

*How `/etc/resolv.conf` turns a hostname into a query, why `ndots:5` costs you latency, and how to watch every step of it happen.*

---

## Table of Contents

1. [The mental model](#1-the-mental-model)
2. [Anatomy of `/etc/resolv.conf`](#2-anatomy-of-etcresolvconf)
3. [What `ndots` actually does](#3-what-ndots-actually-does)
4. [The expansion algorithm, precisely](#4-the-expansion-algorithm-precisely)
5. [Worked examples](#5-worked-examples)
6. [The Kubernetes case](#6-the-kubernetes-case)
7. [Escape hatches and overrides](#7-escape-hatches-and-overrides)
8. [Implementation differences (glibc / musl / systemd-resolved / Go)](#8-implementation-differences)
9. [Observability: watching it happen](#9-observability-watching-it-happen)
10. [A diagnosis playbook](#10-a-diagnosis-playbook)
11. [Tuning guidance](#11-tuning-guidance)
12. [Cheat sheet](#12-cheat-sheet)

---

## 1. The mental model

There is no DNS daemon involved in most application lookups. When your program calls
`getaddrinfo("api.example.com", ...)`, the **stub resolver** — a library built into libc —
does the work in-process. `/etc/resolv.conf` is that library's config file.

The stub resolver's job has two halves:

1. **Name construction** — turn the string you passed into one or more fully qualified
   domain names to actually ask about. This is where `search` and `ndots` live.
2. **Transport** — send those queries to the servers in `nameserver` lines, honoring
   `timeout`, `attempts`, `rotate`, etc.

Nearly all "DNS is slow" mysteries live in half #1. The resolver is not slow; it is
asking four questions when it only needed to ask one.

A crucial consequence: **`resolv.conf` is read by the client, not the server.** Your
upstream DNS server never sees `web`; it sees `web.default.svc.cluster.local`. The
expansion happened on your machine before a packet left it.

---

## 2. Anatomy of `/etc/resolv.conf`

```
# Servers, tried in order. Max 3 (MAXNS) in glibc; extras are silently ignored.
nameserver 10.96.0.10
nameserver 1.1.1.1

# Suffixes to append to non-FQDNs. Max 6 (MAXDNSRCH) in glibc.
search default.svc.cluster.local svc.cluster.local cluster.local

# Legacy single-suffix form. Mutually exclusive with `search`; last one wins.
# domain example.com

# Behavioral knobs.
options ndots:5 timeout:2 attempts:2 rotate single-request-reopen edns0 trust-ad
```

### Directives worth knowing

| Directive | Meaning | Notes |
|---|---|---|
| `nameserver IP` | Upstream resolver | glibc uses max 3; tried sequentially on timeout |
| `search a b c` | Suffix list | glibc max 6, historically 256 chars total |
| `domain X` | Equivalent to `search X` | Deprecated; don't mix with `search` |
| `options ndots:N` | Absolute-vs-search threshold | Default `1`, glibc clamps to max `15` |
| `options timeout:N` | Seconds per server per attempt | Default `5`. glibc caps at 30 |
| `options attempts:N` | Rounds through the whole server list | Default `2`. glibc caps at 5 |
| `options rotate` | Round-robin the nameservers | Spreads load; makes debugging non-deterministic |
| `options single-request` | Send A, then AAAA sequentially | Workaround for middleboxes that drop parallel queries |
| `options single-request-reopen` | Same, plus a new socket per query | For NAT devices that mangle same-port replies |
| `options no-aaaa` | Suppress AAAA lookups entirely | glibc ≥ 2.36 only |
| `options use-vc` | Force TCP | Useful for large responses / debugging truncation |
| `options edns0` | Advertise EDNS0 | Bigger UDP payloads |
| `options trust-ad` | Propagate the AD (authenticated data) bit | glibc ≥ 2.31 |
| `options inet6` | Prefer AAAA lookups | Legacy; rarely what you want |

**Worst-case latency math:** `timeout × attempts × nameservers × search_entries × address_families`.
With `ndots:5`, three search domains, two nameservers, `timeout:5`, `attempts:2`, a
lookup for a name that doesn't exist can theoretically stall for well over a minute.
This is how a single typo'd hostname takes down a service's p99.

---

## 3. What `ndots` actually does

> **`ndots:N` means: if the name you're resolving contains *fewer than N dots*, the
> resolver assumes it is a short/relative name and tries the `search` suffixes
> **before** querying the name literally. If it contains **N or more** dots, the
> literal name is tried **first**.**

Three things people commonly get wrong:

1. **`ndots` is about ordering, not exclusion.** Both forms get tried either way (unless
   the name is fully qualified with a trailing dot). `ndots` only decides which goes first.
2. **It counts dots in the *query string*, not label count.** `a.b` has 1 dot.
   `api.example.com` has 2 dots. `api.example.com.` — a trailing dot — is special-cased
   as absolute and bypasses the logic entirely.
3. **A high `ndots` doesn't make lookups "more thorough."** It makes short names work
   and long names slow. It's a tradeoff dial, not a quality dial.

### Why the default is 1

With `ndots:1`, only single-label names (`web`, `db`, `localhost`) get search-expanded
first. Anything with a dot in it is assumed to be a real domain and queried directly.
For a normal workstation or server this is exactly right.

---

## 4. The expansion algorithm, precisely

glibc's `res_query`/`res_search` path, simplified:

```
INPUT: name, search[], ndots

if name ends with '.':
    query(strip_trailing_dot(name))        # absolute, one query only
    STOP

dots = count('.', name)

if dots >= ndots:
    if query(name) succeeds: STOP          # try as-is FIRST
    for s in search:
        if query(name + "." + s) succeeds: STOP
else:
    for s in search:
        if query(name + "." + s) succeeds: STOP   # try search FIRST
    if query(name) succeeds: STOP
```

Two additional subtleties:

- **A "success" is a positive answer.** `NXDOMAIN` and `NODATA` both cause the resolver
  to continue down the list. A `SERVFAIL` or timeout may abort the whole sequence
  depending on version and error class — which is why a flaky upstream produces
  *intermittent* failures rather than consistent ones.
- **Each step is really two queries.** `getaddrinfo` with `AF_UNSPEC` (the default for
  almost every application) issues an **A** and an **AAAA** query, normally in parallel
  on the same socket. So "4 lookups" on the wire is 8 packets out, 8 in.

---

## 5. Worked examples

Assume throughout:

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

### Example A — single-label name (`web`)

`dots = 0`, which is `< 5` → search list first.

| # | Query sent | Result |
|---|---|---|
| 1 | `web.default.svc.cluster.local` | ✅ NOERROR — **stop** |

One round trip. This is `ndots` working as intended.

### Example B — service in another namespace (`web.staging`)

`dots = 1 < 5` → search list first.

| # | Query sent | Result |
|---|---|---|
| 1 | `web.staging.default.svc.cluster.local` | NXDOMAIN |
| 2 | `web.staging.svc.cluster.local` | ✅ NOERROR — **stop** |

Two round trips. This is *why* Kubernetes sets `ndots:5` — it makes
`service.namespace` and `service.namespace.svc` resolve without an FQDN.

### Example C — external domain, the expensive case (`api.example.com`)

`dots = 2`, still `< 5` → search list first, even though this is obviously a public name.

| # | Query sent | Result |
|---|---|---|
| 1 | `api.example.com.default.svc.cluster.local` | NXDOMAIN |
| 2 | `api.example.com.svc.cluster.local` | NXDOMAIN |
| 3 | `api.example.com.cluster.local` | NXDOMAIN |
| 4 | `api.example.com` | ✅ NOERROR — **stop** |

**Four round trips, eight UDP query packets**, three of which were guaranteed garbage.
Every outbound HTTP call in your application pays this tax unless something caches it.

### Example D — same name under `ndots:1`

`dots = 2 >= 1` → literal first.

| # | Query sent | Result |
|---|---|---|
| 1 | `api.example.com` | ✅ NOERROR — **stop** |

One round trip. But note `web.staging` would now break (it would try `web.staging`
literally first, get NXDOMAIN, then still fall through to the search list — so it
*works*, just in 2 hops instead of 2 hops. The real breakage is with `ndots:0`-style
assumptions or when a public TLD collides with your short name).

### Example E — trailing dot (`api.example.com.`)

Absolute. Search list is never consulted, regardless of `ndots`.

| # | Query sent | Result |
|---|---|---|
| 1 | `api.example.com` | ✅ NOERROR — **stop** |

### Example F — the collision hazard

With `search corp.example.com` and a name like `dev.ai` (`dots = 1`, `ndots:5`):

| # | Query sent | Result |
|---|---|---|
| 1 | `dev.ai.corp.example.com` | ✅ NOERROR — **stop** ⚠️ |

If someone registered an internal `dev.ai.corp.example.com`, you silently reach the
internal host instead of the public `dev.ai`. Search lists are a **name-hijacking
surface**, which is one reason wildcard internal zones plus high `ndots` is a bad combo.

---

## 6. The Kubernetes case

kubelet writes this into every pod with `dnsPolicy: ClusterFirst`:

```
nameserver 10.96.0.10
search <namespace>.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` is chosen so that all four of these forms resolve without an FQDN:

| Form | Dots | Needs search? |
|---|---|---|
| `web` | 0 | yes |
| `web.staging` | 1 | yes |
| `web.staging.svc` | 2 | yes |
| `web.staging.svc.cluster` | 3 | yes |
| `web.staging.svc.cluster.local` | 4 | yes (still `< 5`, but hits on… nothing) |

Note the last row: the canonical FQDN `web.staging.svc.cluster.local` has **4 dots**,
so even it walks the search list first and burns three NXDOMAINs. Writing
`web.staging.svc.cluster.local.` **with the trailing dot** is the correct, fast form.

### Per-pod override

Don't edit `/etc/resolv.conf` in the container — kubelet rewrites it, and an initContainer
hack won't survive restarts. Use `dnsConfig`:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
      - name: single-request-reopen
  dnsPolicy: ClusterFirst
```

`ndots:2` is a common sweet spot: `web` and `web.namespace` still resolve via search,
while anything with two or more dots (i.e. every public domain) goes direct.

### Cluster-wide alternatives

- **NodeLocal DNSCache** — a per-node caching agent; turns the NXDOMAIN storm into
  local cache hits without changing `ndots`.
- **CoreDNS `autopath` plugin** — server-side search-list shortcutting; CoreDNS
  recognizes the expansion pattern and returns a CNAME to the right answer on the
  first query. Costs memory (needs to watch pods) and is easy to misconfigure.
- **Just use FQDNs with trailing dots** in application config. Unglamorous, free, effective.

---

## 7. Escape hatches and overrides

### Trailing dot — the zero-config fix

```bash
curl https://api.example.com./v1/health
```

Works in curl, and in most libraries that pass the hostname through to `getaddrinfo`.
**Caveats:** it can break TLS SNI/certificate matching in some stacks, and HTTP `Host`
header comparisons, and some cloud load balancers reject it. Test before adopting broadly.

### `RES_OPTIONS` — per-process override, no file edits

```bash
RES_OPTIONS="ndots:1 timeout:1 attempts:1" curl -s https://api.example.com/
```

This is the single most useful debugging tool in this document. It lets you A/B a
theory in one command, inside a running container, with no restart.

### `LOCALDOMAIN` — override the search list per-process

```bash
LOCALDOMAIN="" getent hosts api.example.com     # search list disabled entirely
LOCALDOMAIN="corp.example.com" getent hosts web
```

### `RES_OPTIONS` in a Deployment

```yaml
env:
  - name: RES_OPTIONS
    value: "ndots:2"
```

Useful when you can't touch `dnsConfig` (e.g. a chart you don't control) but can set env vars.

---

## 8. Implementation differences

Not everything reads `resolv.conf` the same way. This is a frequent source of
"but it works on my machine."

### glibc (Debian, Ubuntu, RHEL, most base images)

The reference behavior described above. Reads `/etc/resolv.conf` on each lookup
(stat-based cache since 2.26). Honors `ndots` up to 15, `search` up to 6 entries.
`options debug` exists but is a **no-op in virtually all distro builds** because
`RES_DEBUG` output requires a debug-compiled resolver — don't waste time on it.

### musl (Alpine)

- Parses `search`, `ndots`, `timeout`, `attempts`.
- **Always queries A and AAAA in parallel**, and sends to **all** nameservers
  concurrently rather than sequentially — so `rotate`, `single-request`, and
  per-server failover semantics differ or are ignored.
- Historically had a much lower tolerance for large search lists and no `/etc/nsswitch.conf`
  support (musl does not consult NSS the way glibc does).
- Practical effect: Alpine containers often show *different* DNS failure modes than
  Debian ones for the identical `resolv.conf`. Always confirm which libc you're on:
  ```bash
  ldd /bin/sh 2>&1 | head -1     # "musl" vs "GNU libc"
  ```

### systemd-resolved

If `/etc/resolv.conf` is a symlink to `/run/systemd/resolve/stub-resolv.conf`, it
contains `nameserver 127.0.0.53` and the *real* configuration lives in resolved.
The `search` domains there are per-link and have their own routing rules
(`~domain` routing-only domains). `ndots` handling is resolved's own, not glibc's.

```bash
ls -l /etc/resolv.conf          # is it a symlink? to where?
resolvectl status               # the actual effective config
resolvectl domain               # per-interface search/routing domains
```

### Go binaries

Go has **two** resolvers: a pure-Go one and a cgo one that calls `getaddrinfo`.
The pure-Go resolver reads `/etc/resolv.conf` itself and implements `ndots`
(clamping to 0–15), but its behavior around `nsswitch.conf`, `hosts`, and error
retries is not identical to glibc.

```bash
GODEBUG=netdns=go+2   ./yourbinary    # force pure-Go resolver, verbosity 2
GODEBUG=netdns=cgo+2  ./yourbinary    # force cgo/getaddrinfo path
```

The `+1` / `+2` suffix makes Go **print which resolver it chose** to stderr — extremely
useful, and one of the few resolvers with built-in verbosity.

### Java

The JVM caches DNS results in-process (`networkaddress.cache.ttl`), historically
*forever* for positive lookups under a security manager. A Java app can appear immune
to `ndots` problems (it only resolves once) while also being immune to your DNS fixes.

---

## 9. Observability: watching it happen

Ordered roughly from "least invasive" to "ground truth."

### 9.1 `dig +search` — simulate the resolver

**`dig` ignores your search list by default.** This is the #1 reason people conclude
"DNS is fine" while their app is timing out. You must ask for it:

```bash
dig +search api.example.com            # honor search list + ndots from resolv.conf
dig +search +ndots=2 api.example.com   # override ndots for this query only
dig +nosearch api.example.com          # explicit default behavior
```

Add `+noall +answer` to trim output, and `+stats` to see query time:

```bash
dig +search +noall +answer +stats api.example.com
```

Note that even with `+search`, dig reports only the *successful* query — it won't show
you the three NXDOMAINs it burned. For that, go to §9.4 or §9.5.

### 9.2 `getent` — use the real NSS path

`getent` goes through `nsswitch.conf` and `getaddrinfo`, exactly like your application.
`dig` does not. When you want to know what your app will experience, use `getent`:

```bash
getent hosts api.example.com          # AF_UNSPEC, like most apps
getent ahostsv4 api.example.com       # A only
getent ahostsv6 api.example.com       # AAAA only
```

Time it to quantify the tax:

```bash
time getent hosts api.example.com
RES_OPTIONS="ndots:1" bash -c 'time getent hosts api.example.com'
```

A crude but effective benchmark loop:

```bash
for n in 1 2 5; do
  echo -n "ndots:$n  "
  RES_OPTIONS="ndots:$n" \
    bash -c 'S=$(date +%s%N); for i in $(seq 50); do getent hosts api.example.com >/dev/null; done; E=$(date +%s%N); echo "$(( (E-S)/50000000 )) ms/lookup"'
done
```

### 9.3 `host -v` and `drill` / `kdig`

```bash
host -v -a api.example.com
drill -V5 api.example.com          # ldns; V5 dumps full packet detail
kdig +search +stats api.example.com  # knot-dnsutils; nicer stats than dig
```

### 9.4 `strace` — see every syscall the resolver makes

This is the highest-signal, lowest-setup way to see the expansion. You get the exact
byte strings sent, in order, with no packet capture privileges needed beyond ptrace.

```bash
strace -f -e trace=network -s 200 getent hosts api.example.com 2>&1 | grep -a sendto
```

Cleaner, showing the DNS names in the payloads:

```bash
strace -f -e trace=sendto,recvfrom -s 4096 -o /tmp/dns.trace getent hosts api.example.com
grep -aoE '[a-z0-9.-]+\\.(local|com|net|org)' /tmp/dns.trace | sort -u
```

You will literally see four `sendto()` pairs for Example C above. Also watch for:

- `openat("/etc/resolv.conf", ...)` — confirms the file is being read at all
- `connect(...127.0.0.53...)` — you're on systemd-resolved, not talking to the network
- `openat("/etc/nsswitch.conf")` and subsequent `.so` loads — the NSS module chain

To trace an already-running process:

```bash
strace -f -p <PID> -e trace=network -s 200 -o /tmp/app-dns.trace
```

### 9.5 `tcpdump` / `tshark` — ground truth on the wire

Nothing lies here. This is what actually left the box.

```bash
sudo tcpdump -i any -n -s0 port 53
```

Verbose, with full DNS decode:

```bash
sudo tcpdump -i any -n -vvv -s0 'udp port 53 or tcp port 53'
```

`tshark` gives you structured, filterable output that's far easier to read:

```bash
sudo tshark -i any -f 'port 53' -Y dns \
  -T fields -e frame.time_relative -e dns.flags.response \
  -e dns.qry.name -e dns.qry.type -e dns.flags.rcode -E header=y
```

Interpreting: rcode `3` is NXDOMAIN. Seeing three `3`s followed by a `0` for the same
base name is the `ndots` signature, unmistakable once you've seen it.

Capture to a file for later analysis:

```bash
sudo tcpdump -i any -n -s0 -w /tmp/dns.pcap port 53
# ... reproduce the issue ...
tshark -r /tmp/dns.pcap -Y 'dns.flags.rcode == 3' -T fields -e dns.qry.name | sort | uniq -c | sort -rn
```

That last command gives you a **ranked list of your most wasteful queries** — usually
an immediate, actionable answer.

### 9.6 In-container capture without tcpdump installed

Most slim images have no capture tools. Enter the pod's network namespace from the node:

```bash
# Find the container PID on the node
PID=$(crictl inspect --output go-template --template '{{.info.pid}}' <container-id>)
sudo nsenter -t $PID -n tcpdump -i any -n port 53
```

Or with an ephemeral debug container:

```bash
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container> -- bash
# netshoot has dig, tcpdump, tshark, strace, drill, etc.
```

### 9.7 systemd-resolved debug logging

```bash
sudo resolvectl log-level debug          # or: systemctl service-log-level systemd-resolved debug
journalctl -u systemd-resolved -f
# ... reproduce ...
sudo resolvectl log-level info
```

Also useful:

```bash
resolvectl query --cache=no api.example.com    # bypass the cache
resolvectl statistics                          # cache hit rates
resolvectl flush-caches
```

### 9.8 CoreDNS server-side view (Kubernetes)

Turn on the `log` plugin to see the expansion from the server's perspective — you'll
see the same NXDOMAIN storm arriving from every pod:

```
# ConfigMap coredns, Corefile
.:53 {
    log
    errors
    health
    ...
}
```

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns -f | grep NXDOMAIN
```

CoreDNS also exposes Prometheus metrics — `coredns_dns_responses_total{rcode="NXDOMAIN"}`
climbing far faster than `rcode="NOERROR"` is the cluster-wide version of this symptom.

### 9.9 `bpftrace` — latency attribution without ptrace overhead

Measure `getaddrinfo` duration per call, in production, at low cost:

```bash
sudo bpftrace -e '
uprobe:/lib/x86_64-linux-gnu/libc.so.6:getaddrinfo {
  @start[tid] = nsecs;
  @name[tid] = str(arg0);
}
uretprobe:/lib/x86_64-linux-gnu/libc.so.6:getaddrinfo /@start[tid]/ {
  printf("%-40s %6d ms\n", @name[tid], (nsecs - @start[tid]) / 1000000);
  delete(@start[tid]); delete(@name[tid]);
}'
```

Adjust the libc path for your distro (`ldd $(which curl) | grep libc`).

### 9.10 `ltrace` and `perf`

```bash
ltrace -e 'getaddrinfo*' curl -s https://api.example.com/ 2>&1 | head
perf trace -e 'net:*' -p <PID>
```

### 9.11 The `options debug` myth

You'll find advice to add `options debug` to `resolv.conf`. In glibc as shipped by
essentially every distribution, this produces **no output**, because the debug printing
paths are compiled out. Don't chase it; use `strace` or `tcpdump` instead.

---

## 10. A diagnosis playbook

**Symptom:** intermittent slow requests, p99 latency spikes on outbound HTTP, or
"connection timed out" that resolves fine when you retry.

```bash
# 1. What is the resolver configured to do?
cat /etc/resolv.conf; ls -l /etc/resolv.conf

# 2. Which libc / resolver is the app actually using?
ldd /proc/<PID>/exe | head -3
# For Go: GODEBUG=netdns=2 and check stderr

# 3. Does the app's real path (NSS) behave differently from dig?
dig +noall +answer api.example.com          # direct
getent hosts api.example.com                # via NSS + search

# 4. Prove the expansion is happening.
strace -f -e trace=sendto -s 200 getent hosts api.example.com 2>&1 | grep -ac sendto
#    Expect 2 (A+AAAA) if healthy; 8 means 4 rounds of search expansion.

# 5. Confirm on the wire, and rank the waste.
sudo tcpdump -i any -n -w /tmp/d.pcap port 53 & sleep 30; kill %1
tshark -r /tmp/d.pcap -Y 'dns.flags.rcode==3' -T fields -e dns.qry.name | sort | uniq -c | sort -rn | head

# 6. A/B the fix without changing anything persistent.
time getent hosts api.example.com
RES_OPTIONS="ndots:1" bash -c 'time getent hosts api.example.com'
time getent hosts api.example.com.          # trailing dot
```

If step 6 shows a large delta, you've confirmed `ndots` is the cause and you already
know which of the three fixes (lower `ndots`, trailing dots, or a local cache) works.

---

## 11. Tuning guidance

| Environment | Recommended | Reasoning |
|---|---|---|
| Workstation / bare server | `ndots:1` (default) | Short names are rare; don't pay the tax |
| Corporate network with a search domain | `ndots:1`, single `search` entry | Keeps `intranet` working, everything else direct |
| Kubernetes, mostly internal traffic | leave `ndots:5` | Cross-namespace short names are the common case |
| Kubernetes, mostly external traffic | `ndots:2` via `dnsConfig` | `svc` and `svc.ns` still work; public domains go direct |
| Kubernetes, high-volume egress | `ndots:2` **and** NodeLocal DNSCache | Cuts both the count and the cost of each query |
| Anything latency-critical | FQDNs with trailing dots in config | Deterministic, one round trip, no config drift |

**Additional levers:**

- `options timeout:1 attempts:2` — fail fast rather than stalling 5s per server.
  Only safe if your DNS servers are genuinely local and reliable.
- `options single-request-reopen` — if you see AAAA queries mysteriously timing out
  behind a NAT/firewall while A queries succeed.
- `options no-aaaa` (glibc ≥ 2.36) — halves query count on IPv4-only networks. Blunt
  instrument; breaks you the day you get IPv6.
- Application-level DNS caching or connection pooling often beats all of the above.
  A persistent HTTP connection resolves once.

**Don't:**

- Set `ndots:0` — it disables search entirely in a way that surprises people, and
  glibc's handling of it has historically been inconsistent.
- Add more than 3 `nameserver` lines under glibc — silently ignored, and the false
  sense of redundancy will bite you.
- Edit `/etc/resolv.conf` inside a Kubernetes container — kubelet overwrites it.
- Assume `dig` output reflects application behavior. It doesn't, unless you pass `+search`.

---

## 12. Cheat sheet

```bash
# --- Inspect ---
cat /etc/resolv.conf
ls -l /etc/resolv.conf                    # symlink => systemd-resolved
resolvectl status                         # real config under systemd-resolved
ldd /bin/sh | head -1                     # glibc vs musl

# --- Simulate the resolver ---
dig +search api.example.com               # honor search + ndots
dig +search +ndots=2 api.example.com      # override ndots
getent hosts api.example.com              # real NSS path, like your app
getent hosts api.example.com.             # absolute, skips search

# --- Override without editing files ---
RES_OPTIONS="ndots:1" <command>
RES_OPTIONS="ndots:2 timeout:1 attempts:1" <command>
LOCALDOMAIN="" <command>                  # disable search list
GODEBUG=netdns=go+2 <go-binary>           # Go: pick resolver + verbosity

# --- See it happen ---
strace -f -e trace=sendto -s 200 getent hosts api.example.com
sudo tcpdump -i any -n -vvv port 53
sudo tshark -i any -f 'port 53' -Y dns -T fields -e dns.qry.name -e dns.flags.rcode
sudo resolvectl log-level debug && journalctl -u systemd-resolved -f

# --- Kubernetes ---
kubectl exec <pod> -- cat /etc/resolv.conf
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container> -- bash
kubectl -n kube-system logs -l k8s-app=kube-dns | grep NXDOMAIN
```

```yaml
# Per-pod ndots override
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    options:
      - name: ndots
        value: "2"
      - name: single-request-reopen
```

---

## Further reading

- `man 5 resolv.conf` — the authoritative list of options for your specific glibc version
- `man 3 getaddrinfo`, `man 3 res_query`
- RFC 1123 §2.1 and RFC 1535 — the original security concerns about implicit search lists
- Kubernetes docs: *DNS for Services and Pods* → "Pod's DNS Config"
- CoreDNS `autopath` plugin documentation
