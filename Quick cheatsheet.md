# Linux Sysadmin On-Call Cheatsheet

## First 5 Minutes of Any Alert

1. **Acknowledge the alert** so it doesn't escalate past you.
2. **Confirm it's real** — can you reproduce it? Is monitoring itself broken?
3. **Assess blast radius** — one host, one service, or everything?
4. **Check for recent changes** — deploys, config pushes, cron jobs, patching.
5. **Communicate early** — a quick "investigating" in the incident channel buys you time.

Quick triage on any box:

```bash
uptime                # load averages — is the box struggling?
dmesg -T | tail -50   # kernel messages: OOM kills, disk errors, NIC flaps
df -h                 # any filesystem full?
free -h               # memory / swap pressure
top                   # what's eating CPU/memory right now
systemctl --failed    # any failed units?
last -x | head        # recent reboots/shutdowns
```

---

## Scenario 1: Disk Full

**Symptoms:** apps crashing, "No space left on device", DB write failures.

```bash
df -h                          # which filesystem?
df -i                          # inodes can be full even when space isn't!
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15   # biggest dirs
lsof +L1                       # deleted-but-open files still holding space
journalctl --disk-usage        # journal logs can balloon
```

**Common fixes:**
```bash
journalctl --vacuum-size=500M          # shrink systemd journal
find /var/log -name "*.gz" -mtime +30 -delete   # old rotated logs
truncate -s 0 /var/log/huge.log        # empty a log WITHOUT deleting it
systemctl restart <service>            # release deleted-but-open files
```

> ⚠️ Never `rm` an open log file — the process keeps the space until restart. Use `truncate` instead.

---

## Scenario 2: High Load / CPU

### Step 1: Understand the load numbers

```bash
uptime
# load average: 8.50, 6.20, 3.10   ← 1-min, 5-min, 15-min
nproc                               # number of CPU cores
```

- **Load ÷ cores** is what matters. Load 8 on a 16-core box = fine. Load 8 on 2 cores = trouble.
- **1-min > 15-min** → problem is getting worse (or just started).
- **1-min < 15-min** → problem is recovering; you may just be seeing the tail.
- Load counts processes **running OR waiting** (CPU *and* uninterruptible I/O), so high load ≠ high CPU. Diagnose which one it is before acting.

### Step 2: Is it actually CPU?

```bash
top          # look at the %Cpu(s) line:
# us = user space (app code)      → an application is busy
# sy = system/kernel              → syscall-heavy, possibly a kernel/driver issue
# wa = iowait                     → NOT a CPU problem, it's disk/NFS (go to Step 4)
# st = steal (VMs)                → the *hypervisor* is starving you; noisy neighbor
# id = idle
vmstat 1 5   # 'r' column = run queue. r consistently > cores = real CPU saturation
             # 'cs' = context switches; huge numbers = thrashing between processes
mpstat -P ALL 1   # per-core view: one core pinned at 100% = single-threaded culprit
```

### Step 3: Find and handle the culprit

```bash
top -o %CPU                        # or: htop (F6 to sort)
ps aux --sort=-%cpu | head -10
pidstat 1 5                        # per-process CPU over time, catches spiky procs
top -H -p <pid>                    # which THREAD inside the process is hot
ps -o pid,ppid,user,etime,cmd -p <pid>   # how long has it run? who started it? parent?
strace -c -p <pid>                 # (careful, slows target) syscall profile
perf top                           # if installed: what code is actually burning CPU
```

**Then decide:**
```bash
renice +19 -p <pid>                # de-prioritize but keep it running (safest)
ionice -c3 -p <pid>                # also de-prioritize its disk I/O
kill -15 <pid>                     # graceful stop; wait 10s
kill -9 <pid>                      # last resort only
systemctl restart <svc>            # if it's a managed service, restart properly
```

**Common root causes to check:**
- Runaway cron or backup job (`ps -ef | grep -i backup`, check `etime`)
- Log-spamming app burning CPU on I/O + string formatting
- Infinite loop after a bad deploy (did it start right after a release?)
- Too many worker processes (e.g., misconfigured nginx/php-fpm/gunicorn worker count)
- Crypto-miner malware — unknown process, weird name, high CPU: **treat as security incident, escalate, don't just kill it**

### Step 4: High load but LOW CPU (the classic trap)

This means processes are stuck waiting, usually on disk or NFS:

```bash
top                          # %wa high?
ps aux | awk '$8 ~ /^D/'     # D state = uninterruptible sleep (I/O)
iostat -xz 1                 # %util ~100 or await spiking = saturated/dying disk
dmesg -T | tail -30          # I/O errors? "task blocked for more than 120 seconds"?
mount | grep nfs             # stuck NFS mount will send load to the moon
```

- D-state processes **cannot be killed**, even with `-9` — fix the underlying I/O (remount NFS, address the disk) and they'll unstick.
- A hung NFS server can drive load into the hundreds while CPU sits idle. `umount -f` / `umount -l` the stale mount if the server is truly gone.

---

## Scenario 3: Out of Memory / OOM Kills

### Step 1: Read `free -h` correctly

```bash
free -h
#               total   used   free   shared  buff/cache  available
```

- **`available` is the number that matters**, not `free`. Linux deliberately uses spare RAM for cache — low `free` with high `available` is **healthy**, not a problem.
- Real trouble = `available` near zero, or swap heavily used *and actively churning*.
- `shared` includes tmpfs — a huge file dumped into `/tmp` or `/dev/shm` (if tmpfs) eats RAM invisibly: `df -h /dev/shm /tmp; du -sh /dev/shm/*`

### Step 2: Did the OOM killer already strike?

```bash
dmesg -T | grep -iE "out of memory|oom"
journalctl -k --since "1 hour ago" | grep -i oom
# The OOM log shows a table of processes and which one was killed —
# note the killed PID's name AND what was hogging (often not the same process!)
```

The OOM killer kills the process with the highest **oom_score**, which is often a big-but-innocent process (like your database) rather than the actual leaker. Check who was hogging in the dump table.

### Step 3: Who's using the memory NOW?

```bash
ps aux --sort=-%mem | head -10
top -o %MEM
smem -tk                        # if installed: PSS = fairest per-process number
# RSS vs VSZ: RSS = actual RAM used; VSZ = virtual/reserved. Judge by RSS.
cat /proc/meminfo | head -20    # the full picture
slabtop -o | head -15           # kernel slab — dentry/inode caches can balloon
watch -n5 'ps -o rss,cmd -p <pid>'   # is a specific process growing? = leak
```

### Step 4: Check swap behavior

```bash
swapon --show
vmstat 1 5
# si/so columns = swap in/out per second.
# Occasional swap USAGE is fine. Continuous si/so activity = thrashing = the emergency.
```

- Thrashing symptoms: system crawling, disk light solid, everything slow but CPU idle-ish.
- Find what's sitting in swap: `for f in /proc/[0-9]*/status; do awk '/^Name|^VmSwap/' $f; done | paste - - | sort -k3 -rn | head`

### Step 5: Mitigate

```bash
systemctl restart <leaky-svc>       # frees its memory immediately; ticket the leak
kill -15 <pid>                      # if it's not a managed service
sync; echo 3 > /proc/sys/vm/drop_caches   # drops page cache — usually POINTLESS
                                    # (cache is reclaimed automatically); only useful
                                    # for slab pressure edge cases. Don't cargo-cult it.
```

**If a service keeps getting OOM-killed:**
```bash
systemctl show <svc> | grep -i memory      # MemoryMax/MemoryLimit set too low?
systemd-cgtop                              # live per-cgroup usage
cat /proc/<pid>/oom_score_adj              # -1000 protects a process from OOM killer
echo -1000 > /proc/<pid>/oom_score_adj    # e.g., protect sshd/DB (use sparingly)
```

**Common root causes:**
- Memory leak after a deploy (compare start time: `ps -o etime,rss,cmd -p <pid>`)
- Too many app workers × per-worker memory (classic with php-fpm, gunicorn, JVM heaps)
- JVM heap (`-Xmx`) set larger than the box actually has, once container/cgroup limits are counted
- Huge query or import loading a whole dataset into memory
- tmpfs filling up with files (counted as memory!)
- No swap at all on a tight box: a small swap file smooths spikes —
  `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`

---

## Scenario 4: Service Down / Won't Start

```bash
systemctl status <svc>          # state + last log lines
journalctl -u <svc> -n 100 --no-pager
journalctl -u <svc> --since "10 min ago"
systemctl restart <svc>
```

**If restart fails, check in order:**
1. Config syntax — many daemons can self-test: `nginx -t`, `sshd -t`, `apachectl configtest`, `named-checkconf`
2. Port conflict: `ss -tlnp | grep <port>`
3. Permissions/ownership on data dirs, sockets, PID files
4. Disk full (see Scenario 1) — a shockingly common root cause
5. Recently expired certificate (see Scenario 8)

---

## Scenario 5: Network / Connectivity Issues

```bash
ip a && ip r                    # interfaces up? routes sane?
ping -c3 <gateway>              # layer 3 to gateway
ping -c3 8.8.8.8                # internet reachable?
dig example.com                 # DNS working? (vs ping by IP)
ss -tlnp                        # is the service actually listening?
curl -v http://localhost:<port> # works locally but not remotely = firewall
iptables -L -n | head           # or: nft list ruleset / firewall-cmd --list-all
traceroute / mtr <host>         # where does the path break?
```

**Classic pattern:** works by IP, fails by name → DNS. Check `/etc/resolv.conf` and `systemd-resolve --status`.

---

## Scenario 6: Can't SSH Into a Host

- Try the console (iLO/iDRAC/cloud serial console) — that's what it's for.
- From another host: `nc -zv <host> 22` — is the port even open?
- Common causes: disk full (sshd can't write), host actually down, firewall change, `sshd` config broken by recent edit, DNS timeout making login hang (feels like failure — wait 30s).
- If load is extreme, SSH may be alive but glacial: be patient, then use `nice`/`ionice` for your commands.

---

## Scenario 7: Disk I/O Problems

```bash
iostat -xz 1          # %util, await — saturated or slow device?
iotop -o              # who's doing the I/O (needs root)
dmesg -T | grep -iE "error|fail" | grep -i -E "sd|nvme|ata"
smartctl -H /dev/sda  # drive health
cat /proc/mdstat      # RAID degraded?
```

Degraded RAID or SMART failures → page storage/DC team, don't improvise.

---

## Scenario 8: Expired Certificate

```bash
openssl s_client -connect host:443 -servername host </dev/null 2>/dev/null | openssl x509 -noout -dates
openssl x509 -in /path/cert.pem -noout -enddate
certbot renew && systemctl reload nginx    # if Let's Encrypt
```

Remember to **reload** the service after renewing — the old cert stays loaded until then.

---

## Scenario 9: Runaway Log Growth / Log Spam

```bash
ls -lhS /var/log | head
tail -f /var/log/<file>        # what's spamming?
logrotate -d /etc/logrotate.conf   # dry-run: is rotation configured/working?
```

Fix the noisy app if possible; otherwise force a rotation: `logrotate -f /etc/logrotate.d/<conf>`.

---

## Scenario 10: Cron Job Failed or Didn't Run

```bash
journalctl -u cron (or crond) --since today
grep CRON /var/log/syslog       # Debian/Ubuntu
crontab -l -u <user>
systemctl list-timers           # if it's a systemd timer
```

Common causes: PATH differences (cron has a minimal PATH — use absolute paths), missing environment variables, permissions, the job silently failing (add `2>&1 | logger -t myjob`).

---

## Universal Log-Digging Commands

```bash
journalctl -xe                          # recent errors with context
journalctl --since "1 hour ago" -p err  # errors in last hour
journalctl -u <svc> -f                  # follow a service live
grep -riE "error|fail|crit" /var/log/syslog | tail -50
last, lastb                             # logins / failed logins
```

---

## When to Escalate

Escalate **without shame** when:
- Data loss or corruption is possible
- It's security-related (compromise, weird logins, unknown processes)
- Hardware is failing (disks, RAID, PSU)
- You've spent ~30 min with no progress on a user-impacting issue
- The fix requires a change you're not authorized to make

**Golden rules for your first shifts:**
- Mitigate first, root-cause later. A restart that restores service is a win.
- Write down everything you do (commands + timestamps) — future-you and the postmortem will thank you.
- Never run a destructive command you don't fully understand at 3 AM.
- `kill -15` before `kill -9`. Reload before restart. Restart before reboot.
