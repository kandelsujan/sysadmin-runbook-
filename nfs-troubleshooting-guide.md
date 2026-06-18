# NFS Troubleshooting Guide for Linux Administrators

A practical, field-tested reference for diagnosing and fixing NFS problems on Linux. Organized so you can jump straight to a symptom, but the early sections give you the mental model and toolkit that make the symptom sections make sense.

---

## Table of Contents

1. [How NFS Actually Works (the parts that break)](#1-how-nfs-actually-works)
2. [First 5 Minutes: Triage](#2-first-5-minutes-triage)
3. [The Diagnostic Toolkit](#3-the-diagnostic-toolkit)
4. [Symptom-Based Troubleshooting](#4-symptom-based-troubleshooting)
5. [Server-Side Configuration](#5-server-side-configuration)
6. [Client-Side Configuration](#6-client-side-configuration)
7. [NFSv4 Specifics (idmap, pseudo-fs, Kerberos)](#7-nfsv4-specifics)
8. [Locking Problems](#8-locking-problems)
9. [Performance Tuning](#9-performance-tuning)
10. [Firewall & SELinux](#10-firewall--selinux)
11. [Log Locations & What to Look For](#11-log-locations)
12. [Recovery Cookbook](#12-recovery-cookbook)
13. [Quick Reference](#13-quick-reference)

---

## 1. How NFS Actually Works

You can't troubleshoot NFS blind. Know which moving parts exist and which version you're running, because v3 and v4 fail differently.

### Daemons and what they do

| Component | Purpose | Notes |
|-----------|---------|-------|
| `rpc.nfsd` (kernel `nfsd`) | The actual NFS server; serves reads/writes | Listens on port **2049** |
| `rpcbind` (portmapper) | Maps RPC program numbers to ports | **v3 needs it**, v4 does not. Port **111** |
| `rpc.mountd` | Handles mount requests, reads `/etc/exports` | v3 only; dynamic port unless pinned |
| `rpc.statd` (NSM) | Crash/recovery notification for file locks | v3 locking only |
| `lockd` (kernel `NLM`) | Network Lock Manager | v3 locking only; dynamic port |
| `rpc.idmapd` | Maps user/group names ↔ IDs | v4; source of `nobody:nogroup` |
| `rpc.gssd` / `rpc.svcgssd` | GSSAPI/Kerberos security | Only when `sec=krb5*` |

### v3 vs v4 — the key differences

- **v3** is stateless and uses *several* services on *several* ports (rpcbind, mountd, statd, lockd). This is why v3 firewall config is painful — those ports are dynamic by default.
- **v4** is stateful, uses a **single TCP port (2049)**, has **integrated locking and ID mapping**, and does **not require rpcbind**. Mounting uses a pseudo-filesystem root. Firewalling is trivial: just open 2049.

> Rule of thumb: if a mount "hangs forever," suspect network/firewall or a `hard` mount against a down server. If it's "access denied," suspect `/etc/exports`. If files are owned by `nobody`, suspect v4 idmap.

---

## 2. First 5 Minutes: Triage

Run these in order before going deep. Most cases resolve here.

```bash
# 1. Is the server reachable at all?
ping -c3 nfs-server

# 2. Is name resolution sane on BOTH ends? (mismatched DNS/hosts = "access denied")
getent hosts nfs-server
getent hosts nfs-client          # run on the server

# 3. Is the NFS port open from the client?
# v4:
nc -vz nfs-server 2049
# v3 also needs:
nc -vz nfs-server 111

# 4. What does the server claim to export?
showmount -e nfs-server          # works for v3; may be blocked/empty for pure v4

# 5. Are the RPC services actually registered? (server-side or remote)
rpcinfo -p nfs-server

# 6. Current mounts and their negotiated options
mount -t nfs,nfs4
nfsstat -m
```

Decide: **client problem or server problem?** Mount from a *second*, known-good client. If that works, the fault is on the original client. If it fails everywhere, it's the server, network, or export config.

---

## 3. The Diagnostic Toolkit

### Inspecting exports and RPC

```bash
exportfs -v                 # what THIS server is currently exporting (the live table)
exportfs -s                 # condensed list
cat /etc/exports            # the config (not necessarily what's live!)
showmount -e <server>       # exports as seen over the wire
showmount -a <server>       # which clients have mounts (uses mountd; v3-ish)
rpcinfo -p <server>         # registered RPC programs and their ports
rpcinfo -u <server> nfs     # ping the nfs program over UDP
rpcinfo -t <server> nfs 3   # ping nfs v3 over TCP
```

### Inspecting mounts and stats

```bash
nfsstat -m                  # mounted filesystems + the options actually negotiated
nfsstat -c                  # client-side RPC stats
nfsstat -s                  # server-side stats
nfsstat -o all              # per-operation counts
mountstats /mnt/point       # detailed per-op latency (RTT, retransmits)
nfsiostat 2                 # live per-mount I/O like iostat
cat /proc/mounts            # the real mount options the kernel is using
```

### Network-level

```bash
ss -tnp | grep 2049         # active NFS connections
# Capture the actual conversation — invaluable for "access denied" / hangs:
tcpdump -i any -w /tmp/nfs.pcap host nfs-server and \(port 2049 or port 111 or port 20048\)
# then read it in Wireshark; filter on 'nfs' and 'rpc'
```

### Kernel/service messages

```bash
dmesg -T | grep -i nfs
journalctl -u nfs-server -u nfs-mountd -u rpcbind -u rpc-statd --since "1 hour ago"
journalctl -k | grep -iE 'nfs|rpc|lockd'
```

---

## 4. Symptom-Based Troubleshooting

### 4.1 `mount.nfs: Connection timed out` / mount hangs

**Cause:** network path blocked, server down, or wrong port/version.

Checklist:
- `nc -vz server 2049` (and `111` for v3). Blocked → **firewall** between hosts or on the server.
- Force a version to rule out negotiation problems:
  ```bash
  mount -t nfs -o vers=4.2 server:/export /mnt   # try v4 explicitly
  mount -t nfs -o vers=3 server:/export /mnt     # try v3 explicitly
  ```
- For v3, confirm `rpcbind`, `mountd`, `statd` are up on the server (`rpcinfo -p`). Missing entries → start `nfs-server`/`rpcbind`.
- If it hangs *during* normal use and recovers, that's a `hard` mount riding out a server blip — expected behavior, not a bug.

### 4.2 `mount.nfs: access denied by server while mounting`

This is almost always an **export/authorization** problem, not networking.

- On the server, compare the live table to the config:
  ```bash
  exportfs -v
  ```
- The client's resolved name/IP must match an entry in `/etc/exports`. Mismatched forward/reverse DNS is the #1 cause. Verify with `getent hosts` on **both** sides.
- After editing `/etc/exports`, you must re-export:
  ```bash
  exportfs -ra
  ```
- **Classic gotcha — the stray space.** These are NOT equivalent:
  ```
  /data 192.168.1.0/24(rw,sync)      # correct: rw,sync for that subnet
  /data 192.168.1.0/24 (rw,sync)     # WRONG: subnet gets defaults (ro), and the WORLD gets rw!
  ```
- Wildcards/netgroups: `*.lab.example.com`, `@trusted_hosts`. Confirm the client falls inside.

### 4.3 `Permission denied` on files (mount succeeds, access fails)

Mount worked, but you can't read/write. Look at **squashing and IDs**.

- **root_squash** (the default) maps remote root → `anonymous`. So root can't write files owned by root. Either run as a normal matching user, or — knowing the security cost — set `no_root_squash`.
- **all_squash** maps *everyone* to anon (`anonuid`/`anongid`). Great for public read shares, surprising otherwise.
- UID/GID must match between client and server for ownership to make sense (unless you're using v4 name-based idmap or central auth like LDAP/SSSD). A user that is UID 1000 on the client but 1005 on the server will see "wrong" ownership and get denied.
- Export is `ro` but you're trying to write:
  ```bash
  exportfs -v   # look for (ro,...) vs (rw,...)
  ```
- SELinux on the server can block it even when Unix perms are fine — see §10.

### 4.4 Files owned by `nobody:nogroup` (or `nobody:nobody`)

The hallmark **NFSv4 idmap** problem. The numbers map fine but the *names* don't.

- Ensure the **NFSv4 domain matches** on client and server in `/etc/idmapd.conf`:
  ```
  [General]
  Domain = example.com
  ```
- Restart idmap and clear the cache:
  ```bash
  systemctl restart nfs-idmapd        # name varies: nfs-idmapd / rpc-idmapd
  nfsidmap -c                          # clear the kernel idmap cache
  ```
- Modern kernels often **bypass idmap with `sec=sys`** and pass numeric IDs directly. If you *want* numeric passthrough (simplest when UIDs are synced), confirm:
  ```bash
  cat /sys/module/nfs/parameters/nfs4_disable_idmapping     # Y = numeric passthrough on client
  cat /sys/module/nfsd/parameters/nfs4_disable_idmapping    # Y = numeric passthrough on server
  ```
  If you instead rely on *name* mapping, the users/groups must resolve to the same names on both ends (sync `/etc/passwd` or use LDAP/SSSD).

### 4.5 `Stale file handle` (ESTALE)

The handle the client holds no longer points to a valid object on the server.

Common triggers:
- The exported directory was deleted/recreated, or the underlying filesystem was reformatted/remounted, changing inode numbers.
- The server's export `fsid` changed (e.g., after reboot the device order shifted).
- A file was deleted on the server while a client had it open.

Fixes:
```bash
# On the client — try a clean remount:
umount -f /mnt/point   ||  umount -l /mnt/point   # lazy if busy
mount /mnt/point
```
To prevent recurrence, **pin a stable fsid** in `/etc/exports` so handles survive reboots/re-exports:
```
/data  192.168.1.0/24(rw,sync,fsid=1)
```
(For the v4 pseudo-root use `fsid=0` — see §7.)

### 4.6 `Server not responding, still trying` then `OK`

Network hiccup or server overload; the `hard` mount retried and recovered. Not fatal. If frequent:
- Check server load and `nfsd` thread count (§9).
- Look for dropped packets / retransmits: `mountstats /mnt/point` and `ss -i`.
- Check for MTU mismatches if jumbo frames are in play (§9).

### 4.7 Processes stuck in `D` state (uninterruptible sleep), can't kill

Process is blocked in kernel waiting on NFS I/O against an unreachable server — the price of `hard` mounts.

```bash
ps -eo pid,stat,wchan:30,cmd | awk '$2 ~ /D/'
```

You cannot `kill -9` a true `D`-state process. Options:
- **Restore the server / network** — the I/O completes and the process unblocks.
- `umount -l /mnt/point` (lazy unmount) detaches the mount so *new* access doesn't block; existing blocked I/O still needs the server.
- For graceful failure on flaky servers, mount with `soft,timeo=,retrans=` — but understand `soft` risks **data corruption** on writes because it can return an error mid-write. Prefer `hard` for anything you write to; consider `soft` only for read-only data.
- Note: the old `intr` option is **ignored on kernels ≥ 2.6.25**. Don't rely on it.

### 4.8 `RPC: Program not registered`

A required v3 service isn't registered with `rpcbind`.

```bash
rpcinfo -p <server>          # expect: portmapper, nfs, mountd, nlockmgr, status
```
If `mountd` or `nfs` is missing, restart the stack on the server in order:
```bash
systemctl restart rpcbind
systemctl restart nfs-server     # (nfs-kernel-server on Debian/Ubuntu)
```
Or just use v4 (`-o vers=4`), which doesn't need rpcbind at all.

### 4.9 Slow performance

See §9 — but quick wins: check `rsize`/`wsize` (should negotiate up to 1MB on modern stacks), confirm TCP not UDP, count `nfsd` threads, and look at `mountstats` for high RTT or retransmits.

---

## 5. Server-Side Configuration

### /etc/exports syntax

```
/export/path   client(option,option,...)   client2(option,...)
```

### Export options that matter

| Option | Effect |
|--------|--------|
| `rw` / `ro` | read-write / read-only |
| `sync` / `async` | `sync` (default, safe) acks writes only after disk commit; `async` is faster but risks data loss on crash |
| `root_squash` | (default) remote root → anonymous. Keep it unless you have a reason |
| `no_root_squash` | remote root stays root. **Security risk** — use sparingly (e.g., diskless boot) |
| `all_squash` | all users → anonymous; pair with `anonuid=`/`anongid=` |
| `subtree_check` / `no_subtree_check` | `no_subtree_check` (modern default) is faster and avoids rename-while-open bugs |
| `fsid=N` / `fsid=0` | stable filesystem ID; `fsid=0` defines the v4 pseudo-root |
| `sec=sys|krb5|krb5i|krb5p` | security flavor |
| `crossmnt` | let clients traverse into nested mounts under the export |

### Apply changes (you must re-export!)

```bash
exportfs -ra        # re-read /etc/exports and sync the live table
exportfs -v         # verify what's live
exportfs -u host:/path   # unexport one
exportfs -f         # flush the kernel export cache (force re-auth)
```

### Services

```bash
# RHEL/CentOS/Rocky/Alma/Fedora:
systemctl enable --now rpcbind nfs-server
# Debian/Ubuntu:
systemctl enable --now nfs-kernel-server
```

### Tuning thread count (v3 perf, see §9)

```bash
# RHEL 8+/modern: /etc/nfs.conf
[nfsd]
threads=16
# older /etc/sysconfig/nfs: RPCNFSDCOUNT=16
systemctl restart nfs-server
cat /proc/fs/nfsd/threads
```

---

## 6. Client-Side Configuration

### Manual mount

```bash
mount -t nfs  -o vers=4.2 server:/export /mnt/point
mount -t nfs  -o vers=3,proto=tcp server:/export /mnt/point
```

### /etc/fstab entry

```
server:/export  /mnt/point  nfs  _netdev,vers=4.2,hard,rsize=1048576,wsize=1048576,timeo=600,retrans=2  0 0
```

### Key mount options

| Option | Meaning |
|--------|---------|
| `vers=3 / 4 / 4.1 / 4.2` | force protocol version |
| `proto=tcp / udp` | use TCP (default, recommended) |
| `hard` / `soft` | `hard` retries forever (safe for writes); `soft` errors out (corruption risk) |
| `timeo=N` | retransmit timeout in **deciseconds** (e.g., 600 = 60s) |
| `retrans=N` | retries before a `soft` mount errors / a `hard` mount logs "not responding" |
| `rsize=` / `wsize=` | read/write block sizes; let it negotiate to 1MB unless tuning |
| `_netdev` | wait for network before mounting at boot (**critical** for fstab) |
| `bg` / `fg` | mount in background on failure (good for boot resilience) |
| `noac` | disable attribute caching — correctness over speed; big perf hit |
| `nconnect=N` | multiple TCP connections per mount (throughput on fast links) |
| `nolock` | disable NLM locking (v3); only if you know locks aren't needed |

> `_netdev` plus `bg` in fstab prevents a dead NFS server from hanging your boot.

### autofs (mount on demand — avoids boot-time hangs entirely)

```bash
# /etc/auto.master
/mnt/nfs   /etc/auto.nfs   --timeout=60
# /etc/auto.nfs
data   -vers=4.2,hard   server:/export/data
systemctl restart autofs
```

---

## 7. NFSv4 Specifics

### Pseudo-filesystem root

v4 presents a single namespace rooted at the export marked `fsid=0`. Clients mount paths *relative* to that root.

```
# /etc/exports
/srv/nfs            192.168.1.0/24(rw,sync,fsid=0,crossmnt)   # the v4 root
/srv/nfs/data       192.168.1.0/24(rw,sync,no_subtree_check)
```
Client then mounts:
```bash
mount -t nfs -o vers=4 server:/        /mnt/root
mount -t nfs -o vers=4 server:/data    /mnt/data    # NOT /srv/nfs/data
```
A common "mount works but directory is empty/denied" bug is forgetting that v4 paths are relative to `fsid=0`.

### idmap (see also §4.4)

```ini
# /etc/idmapd.conf  — must match on client and server
[General]
Domain = example.com
[Mapping]
Nobody-User = nobody
Nobody-Group = nobody
```
```bash
systemctl restart nfs-idmapd && nfsidmap -c
```

### Kerberos (sec=krb5 / krb5i / krb5p)

- `krb5` = authentication only, `krb5i` = + integrity, `krb5p` = + privacy (encryption).
- Requires working Kerberos: synced clocks (run `chronyd`/NTP!), valid `/etc/krb5.keytab` with `nfs/fqdn` principals on both hosts, and `rpc.gssd` (client) / `rpc.svcgssd` (server) running.
- Symptoms of broken krb5: mount hangs or "access denied," `gssd` errors in the journal. **Check time skew first** — Kerberos fails hard if clocks differ by more than a few minutes.

---

## 8. Locking Problems

Symptoms: `flock`/`fcntl` blocks forever, "resource temporarily unavailable," apps that share files (databases, mail spools) corrupt or stall.

### NFSv3 (NLM)
- Needs `rpc.statd` (status) and `lockd` (locks). Both use **dynamic ports** by default → firewall headaches.
- Verify registration: `rpcinfo -p server | grep -E 'status|nlockmgr'`.
- Pin the ports so you can firewall them:
  ```ini
  # /etc/nfs.conf
  [lockd]
  port = 32803
  udp-port = 32769
  [statd]
  port = 32765
  ```
  Then open those ports (§10) and restart `rpc-statd` / `nfs-server`.
- Stale locks after a client crash: `rpc.statd` should notify on recovery. If locks are stuck, restarting `rpc-statd` on the relevant host and clearing `/var/lib/nfs/sm*` (carefully) can help.

### NFSv4
- Locking is **integrated into the protocol on port 2049** — no statd/lockd, no extra ports. If you're fighting v3 lock-port firewall issues, migrating to v4 makes the problem disappear.

---

## 9. Performance Tuning

Measure first, then change one thing at a time.

```bash
mountstats /mnt/point      # look at avg RTT and "retrans" per operation
nfsiostat 2                # live throughput + latency
nfsstat -o all             # which operations dominate
```

### Levers

- **rsize/wsize:** modern stacks negotiate up to 1 MiB. Confirm with `nfsstat -m`. Tiny sizes (4–32 KiB) throttle throughput.
- **TCP, not UDP:** UDP is fragile on lossy/large-MTU networks and effectively deprecated. Use `proto=tcp`.
- **`nfsd` threads (server):** default (often 8) is too few for busy servers. Bump to 16–64 (see §5). Watch `cat /proc/net/rpc/nfsd` (th line) for threads maxed out.
- **`nconnect=` (client):** open multiple TCP streams per mount to saturate fast (10/25/40G) links.
- **sync vs async:** export `async` is much faster but unsafe on power loss. Use only where data is reproducible.
- **Attribute caching:** the defaults (`ac`, `acregmin/max`, `acdirmin/max`) trade freshness for speed. `noac` kills performance — only use it when strict cross-client consistency is mandatory.
- **Jumbo frames / MTU:** if you set MTU 9000, it must be consistent end-to-end (NICs *and* switches). A mismatch causes silent fragmentation/drops and "still trying" messages. Verify with `ping -M do -s 8972 server`.
- **Read-ahead and underlying storage:** NFS can't be faster than the server's disk and network. Check the server's local I/O too.

---

## 10. Firewall & SELinux

### firewalld (RHEL family)

```bash
# NFSv4 — just one port:
firewall-cmd --permanent --add-service=nfs
# NFSv3 — also need rpcbind + mountd (and pinned statd/lockd ports):
firewall-cmd --permanent --add-service={nfs,rpc-bind,mountd}
firewall-cmd --reload
firewall-cmd --list-services
```

### iptables/nftables
Open TCP 2049 (v4). For v3 add 111 (rpcbind), the mountd port, and your pinned statd/lockd ports.

### SELinux (server)
Even with perfect Unix perms and exports, SELinux can deny NFS. Useful booleans:

```bash
getsebool -a | grep nfs
setsebool -P nfs_export_all_rw 1        # allow exporting any path rw
setsebool -P nfs_export_all_ro 1
setsebool -P use_nfs_home_dirs 1        # on CLIENTS mounting home dirs
```
Check for denials:
```bash
ausearch -m AVC -ts recent | grep nfs
journalctl -t setroubleshoot
```
If a specific path won't export, confirm its context isn't blocking it and consider labeling with `public_content_rw_t` for shared writable data.

---

## 11. Log Locations

| Where | What you'll find |
|-------|------------------|
| `journalctl -u nfs-server` | server start/stop, export errors |
| `journalctl -u nfs-mountd` | mount request denials (great for "access denied") |
| `journalctl -u rpc-statd` | NSM/lock recovery |
| `journalctl -u nfs-idmapd` | v4 name-mapping issues |
| `dmesg -T \| grep -i nfs` | kernel-level: stale handles, "server not responding", protocol errors |
| `/proc/fs/nfsd/*` | live server state (threads, exports, pool stats) |
| `/proc/mounts` | the *actual* mount options in effect |
| `ausearch -m AVC` / `journalctl -t setroubleshoot` | SELinux denials |
| `tcpdump` capture | ground truth when logs are ambiguous |

When in doubt, raise the server's debug level temporarily:
```bash
rpcdebug -m nfsd -s all      # turn on (server); '-c all' to clear
rpcdebug -m nfs  -s all      # client side
# watch dmesg, then ALWAYS turn it back off:
rpcdebug -m nfsd -c all
```

---

## 12. Recovery Cookbook

**Restart the full server stack in dependency order:**
```bash
systemctl restart rpcbind
systemctl restart nfs-server          # nfs-kernel-server on Debian/Ubuntu
systemctl restart nfs-mountd nfs-idmapd rpc-statd 2>/dev/null
exportfs -ra
exportfs -v          # confirm
```

**Clear a stale file handle on a client:**
```bash
umount -f /mnt/point || umount -l /mnt/point
mount /mnt/point
```

**Free a wedged mount whose server is gone:**
```bash
umount -f /mnt/point     # force (may fail if I/O in flight)
umount -l /mnt/point     # lazy: detach now, clean up later
# last resort if processes are pinned in D state: restore the server, then unmount
```

**Force re-authentication after fixing /etc/exports:**
```bash
exportfs -f && exportfs -ra
```

**Flush v4 idmap after fixing the domain:**
```bash
nfsidmap -c
```

**Reset NLM locks after a crash (v3):** stop the client's locking, clear stale state, restart.
```bash
systemctl stop rpc-statd
# inspect /var/lib/nfs/sm and sm.bak before removing anything
systemctl start rpc-statd
```

---

## 13. Quick Reference

### Decision flow

```
Mount fails?
├─ "Connection timed out" / hangs ......... network/firewall, or hard mount vs down server  → §4.1, §10
├─ "access denied by server" .............. /etc/exports + DNS mismatch; exportfs -ra        → §4.2, §5
├─ "Program not registered" ............... rpcbind/mountd not up (v3); or just use v4        → §4.8
└─ mounts but...
   ├─ Permission denied ................... squash/UID mismatch/ro export/SELinux            → §4.3, §10
   ├─ owned by nobody:nogroup ............. v4 idmap domain mismatch                          → §4.4, §7
   ├─ Stale file handle ................... remount; pin fsid                                 → §4.5
   ├─ Slow .............................. rsize/wsize, threads, TCP, mountstats              → §9
   └─ locks hang ........................ NLM ports (v3) or move to v4                       → §8
```

### Most-used commands

```bash
exportfs -rav                 # apply + show exports (server)
showmount -e <server>         # exports over the wire
rpcinfo -p <server>           # registered RPC services
nfsstat -m                    # negotiated mount options/stats (client)
mountstats /mnt/point         # per-op latency
dmesg -T | grep -i nfs        # kernel NFS messages
mount -t nfs -o vers=4.2 server:/export /mnt   # explicit-version test mount
```

### Golden rules

1. **Always re-export** after editing `/etc/exports` (`exportfs -ra`).
2. **Mismatched DNS** between client and server causes most "access denied" errors.
3. **`hard` mounts hang; `soft` mounts corrupt** — pick deliberately; default to `hard` for writable data.
4. **v4 simplifies everything** (one port, integrated locking, no rpcbind). Migrate off v3 if firewall/lock pain is your main issue.
5. **Watch out for the stray space** in `/etc/exports`.
6. **Sync clocks** (chrony/NTP) — mandatory for Kerberos, healthy in general.
7. **Change one variable at a time** when tuning, and measure with `mountstats`.
