# Linux `ulimit` Troubleshooting Guide

A practical reference for diagnosing and fixing resource-limit problems on Linux servers. The single most important idea to internalize: **the limit a process actually runs under is rarely the one you set in the shell you're typing in.** Most wasted hours on ulimit issues come from setting a limit in one place and the process inheriting it from another.

---

## 1. Mental model: where limits come from

Linux resource limits are *per-process* and *inherited by children*. A process gets its limits from whatever launched it, and that chain looks different depending on how the process was started.

```
Kernel hard ceilings (sysctl, e.g. fs.file-max, fs.nr_open)
        │
        ├── Login session  → PAM (pam_limits.so) → /etc/security/limits.conf + limits.d/*
        │        │
        │        └── your shell → child processes (inherit shell's limits)
        │
        ├── systemd service → unit file LimitNOFILE= etc. (DOES NOT read limits.conf)
        │
        └── Container runtime → Docker/Kubernetes ulimit settings (separate again)
```

Three independent worlds — interactive login, systemd, containers — each with its own configuration surface. A change in one does **not** propagate to the others. This is the root cause of most "I increased the limit but it didn't work" tickets.

### Soft vs. hard limits

- **Soft limit**: the value actually enforced right now. A process can raise its own soft limit up to the hard limit without privileges.
- **Hard limit**: the ceiling. Only root (or `CAP_SYS_RESOURCE`) can raise the hard limit.

```bash
ulimit -Sn    # show soft limit for open files
ulimit -Hn    # show hard limit for open files
ulimit -n     # defaults to soft
```

An unprivileged process can do `ulimit -n 8192` only if the hard limit is already ≥ 8192. Setting the hard limit lower than you need and then wondering why the soft limit won't go up is a classic trap.

---

## 2. First moves when something breaks

Before changing anything, find out what the **affected process** is actually running under. Not your shell — the process.

```bash
# The authoritative source of truth for a running process:
cat /proc/<PID>/limits
```

Example output (trimmed):

```
Limit                     Soft Limit   Hard Limit   Units
Max open files            1024         4096         files
Max processes             7900         7900         processes
Max locked memory         65536        65536        bytes
Max core file size        0            unlimited    bytes
```

Compare that against what you *think* you set. If they differ, you set the limit in the wrong place or the process was started before your change.

Other quick diagnostics:

```bash
ulimit -a                      # all limits for current shell
lsof -p <PID> | wc -l          # how many FDs this process has open right now
ls /proc/<PID>/fd | wc -l      # faster equivalent
cat /proc/sys/fs/file-nr       # system-wide: allocated, unused, max FDs
```

---

## 3. The common limits and what they map to

| `ulimit` flag | limits.conf key | systemd key | What it controls |
|---|---|---|---|
| `-n` | `nofile` | `LimitNOFILE` | Open file descriptors (files + sockets) |
| `-u` | `nproc` | `LimitNPROC` | Number of processes/threads for the user |
| `-c` | `core` | `LimitCORE` | Core dump file size |
| `-l` | `memlock` | `LimitMEMLOCK` | Bytes of memory that can be locked (mlock) |
| `-s` | `stack` | `LimitSTACK` | Stack size per thread |
| `-f` | `fsize` | `LimitFSIZE` | Max size of files the process can write |
| `-v` | `as` | `LimitAS` | Virtual address space |
| `-m` | `rss` | `LimitRSS` | Resident set size (largely unenforced on modern kernels) |
| `-t` | `cpu` | `LimitCPU` | CPU time in seconds |

The two you will deal with 90% of the time are **`nofile`** and **`nproc`**.

---

## 4. Symptom-to-cause catalog

This is the part you'll actually come back to. Match the error message to the limit.

### "Too many open files" / `EMFILE` / `errno 24`

The process hit its `nofile` soft limit. Sockets count as file descriptors, so this hits network-heavy services (web servers, databases, message brokers) hard.

```
java.net.SocketException: Too many open files
nginx: accept() failed (24: Too many open files)
accept4(): Too many open files
```

**Diagnose:**
```bash
cat /proc/<PID>/limits | grep "open files"
ls /proc/<PID>/fd | wc -l            # current usage vs. the limit
lsof -p <PID> | awk '{print $5}' | sort | uniq -c | sort -rn   # FD types
```
If usage is near the limit and climbing steadily, you may also have a **file-descriptor leak** (FDs opened and never closed) rather than just a low limit. A flat-but-high count means raise the limit; a steadily growing count means fix the application.

**Distinguish from the system-wide ceiling:**
```bash
cat /proc/sys/fs/file-nr    # third number is fs.file-max
```
`ENFILE` ("Too many open files in system") is the *system-wide* limit (`fs.file-max`), different from the per-process `EMFILE`.

### "Resource temporarily unavailable" / `EAGAIN` on fork/thread creation

Hit the `nproc` limit. Note: `nproc` counts **all** processes/threads owned by that UID across the whole machine, not just the ones in this service. A second instance of an app, or many threads, can exhaust it.

```
fork: retry: Resource temporarily unavailable
java.lang.OutOfMemoryError: unable to create new native thread
pthread_create failed
```

**Diagnose:**
```bash
ps -eLf | grep <user> | wc -l       # threads (-L) owned by user
cat /proc/<PID>/limits | grep processes
```
Beware: on systems where many services run as the same user, one runaway service starves the others.

### Core dumps not being generated

When a process crashes you expect a core file but get nothing. Usually `ulimit -c` is `0`.

```bash
ulimit -c                            # 0 means disabled
cat /proc/<PID>/limits | grep core
cat /proc/sys/kernel/core_pattern    # where cores go (or which handler eats them)
```
Even with `core` unlimited, `core_pattern` may pipe cores to `systemd-coredump` or `apport`. Check `coredumpctl list` on systemd systems — the core may exist, just not where you looked.

### `mlock` / "cannot allocate locked memory" — databases especially

Datastores like Redis, Elasticsearch, Oracle, and Kafka often want to lock memory to prevent swapping. A low `memlock` limit causes startup failures or warnings.

```
WARNING: increased open files... but memlock is too low
mlockall(MCL_CURRENT) failed: Cannot allocate memory
```
Set `memlock` to `unlimited` (or a large value) for that service.

### Stack-related crashes

Deeply recursive code or many threads with large stacks can hit `-s`. Conversely, an *unlimited* stack can also cause problems (the kernel uses the stack limit to size thread stacks). If you see segfaults that scale with thread count, inspect `LimitSTACK`.

### "File size limit exceeded" / `SIGXFSZ`

The process tried to write past `fsize`. Rare unless someone explicitly capped it; check `ulimit -f`.

---

## 5. Setting limits correctly — by context

### A. Interactive / login shells (PAM)

Edit `/etc/security/limits.conf` or, preferably, drop a file in `/etc/security/limits.d/`:

```
# /etc/security/limits.d/90-nofile.conf
# <domain>  <type>  <item>   <value>
appuser     soft    nofile   65535
appuser     hard    nofile   65535
appuser     soft    nproc    8192
appuser     hard    nproc    8192
*           soft    nofile   16384      # wildcard: all users
@developers hard    nproc    4096       # @ = group
```

Requirements and gotchas:
- `pam_limits.so` must be active in the relevant PAM stack (it usually is in `/etc/pam.d/login`, `sshd`, `su`). If a service bypasses PAM, this file is ignored.
- Changes apply to **new** login sessions only. Log out and back in.
- The wildcard `*` does **not** apply to root, and does not override more specific per-user rules.
- On some distros `/etc/security/limits.d/` ships a default `nproc` file (e.g. `20-nproc.conf`) that may already cap things — check it.

### B. systemd services — the #1 gotcha

**systemd services do not read `/etc/security/limits.conf`.** They are not login sessions. Editing limits.conf and restarting the service does nothing. You must set limits in the unit.

```bash
sudo systemctl edit myapp.service
```

Add an override:

```ini
[Service]
LimitNOFILE=65535
LimitNPROC=8192
LimitMEMLOCK=infinity
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart myapp.service
systemctl show myapp.service -p LimitNOFILE -p LimitNPROC   # verify
```

To change it for **all** services at once, set defaults in `/etc/systemd/system.conf`:

```ini
DefaultLimitNOFILE=65535
```
(Then `systemctl daemon-reexec`.) Note `infinity` is systemd's keyword for unlimited, not the word `unlimited`.

### C. The `/etc/security/limits.conf` ↔ systemd confusion, summarized

| Started by… | Reads limits.conf? | Set limit where |
|---|---|---|
| SSH login, `su`, login shell | Yes (via PAM) | `limits.conf` / `limits.d` |
| `systemctl start` / boot service | **No** | unit file `Limit*=` |
| cron job | Sometimes (depends on PAM config for cron) | test it; often unit or limits.d |
| Docker container | No | `--ulimit` / compose / daemon.json |

### D. Containers (Docker / Kubernetes)

Container processes inherit limits from the runtime, not the host's limits.conf.

```bash
docker run --ulimit nofile=65535:65535 myimage
```

docker-compose:
```yaml
services:
  app:
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
```

Daemon-wide default in `/etc/docker/daemon.json`:
```json
{ "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 65535, "Hard": 65535 } } }
```
Kubernetes does not expose ulimits directly in the pod spec for most fields; you typically bake them into the image entrypoint, set them via the container runtime config, or use a privileged init step. `nofile` is often controlled via the runtime (containerd/CRI-O) defaults.

### E. Raising the system-wide kernel ceiling

Per-process limits can't exceed kernel maxima. If you need very high `nofile`:

```bash
# Current ceilings
cat /proc/sys/fs/file-max      # max total open files system-wide
cat /proc/sys/fs/nr_open       # max nofile a single process may be set to

# Persist:
echo 'fs.file-max = 2097152' | sudo tee /etc/sysctl.d/99-limits.conf
echo 'fs.nr_open = 1048576'  | sudo tee -a /etc/sysctl.d/99-limits.conf
sudo sysctl --system
```
If your desired `LimitNOFILE` exceeds `fs.nr_open`, the service will fail to start — raise `fs.nr_open` first.

---

## 6. Verification — always confirm at the process level

Setting a limit and assuming it took is how you end up debugging the same thing twice. After any change, restart the process and check the running process, not your shell:

```bash
# Find the PID
systemctl show -p MainPID myapp.service
pgrep -f myapp

# Confirm from the kernel's view
cat /proc/<PID>/limits
```

A handy one-liner to sanity-check what a freshly-spawned child of a service would get:

```bash
sudo systemd-run --pty --property=LimitNOFILE=65535 /bin/bash -c 'ulimit -n'
```

---

## 7. Decision flow for a "limit" incident

1. **Get the error and the PID.** Identify which limit the error maps to (Section 4).
2. **Read `/proc/<PID>/limits`.** This is ground truth. Note soft and hard.
3. **Measure current usage** (`ls /proc/<PID>/fd | wc -l`, thread count, etc.).
   - Usage ≈ limit and stable → the limit is genuinely too low. Raise it.
   - Usage climbing without bound → suspect a **leak** in the app; raising the limit only delays the crash.
4. **Identify how the process was started** (systemd? login? container?) — this tells you *which config file* to edit (Section 5).
5. **Change the limit in the correct place**, reload/restart.
6. **Re-read `/proc/<PID>/limits`** to confirm the new value is live.
7. If the new value won't stick or is capped, **check the kernel ceiling** (`fs.nr_open`, `fs.file-max`) and the **hard limit**.

---

## 8. Quick command reference

```bash
ulimit -a                          # all limits, current shell
ulimit -Sn / -Hn                   # soft / hard open-files limit
cat /proc/<PID>/limits             # actual limits of a running process  ★
ls /proc/<PID>/fd | wc -l          # FDs currently open by a process
lsof -p <PID> | wc -l              # same, with detail
cat /proc/sys/fs/file-nr           # system-wide FD usage / max
ps -eLf | grep <user> | wc -l      # thread count for a user (nproc check)
coredumpctl list                   # where systemd stashed crash cores

systemctl show <svc> -p LimitNOFILE -p LimitNPROC   # service's effective limits
systemctl edit <svc>               # add a [Service] Limit*= override
sudo sysctl --system               # apply sysctl drop-ins
```

The ★ line is the one to reach for first, every time.

---

## 9. Pitfalls checklist

- Edited `limits.conf` for a **systemd service** — it doesn't read it. Use the unit file.
- Changed a limit but didn't **restart** the process — it keeps the old inherited value.
- Raised the **soft** limit above the **hard** limit as a non-root user — not allowed.
- Set `LimitNOFILE` above `fs.nr_open` — service refuses to start.
- `nproc` exhausted by **all** processes of a shared user, not just the one service.
- Tested in your SSH shell (`ulimit -n` looks fine) but the **service** runs with different limits.
- Used `unlimited` where systemd expects `infinity`.
- Core file "missing" but actually captured by `systemd-coredump` — check `coredumpctl`.
- A distro default file in `limits.d/` silently overriding your value — grep the whole directory.
