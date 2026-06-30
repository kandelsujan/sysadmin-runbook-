# systemd-run: A Practical Guide for Linux Administrators

*Running commands, scripts, and jobs as transient systemd units — with a deep
section on passing arguments, environment variables, and secrets*

---

## 1. The core idea in one paragraph

`systemd-run` takes any command and **promotes it to a real systemd unit that
PID 1 creates on the fly** — a *transient* unit, meaning you get everything a
hand-written `.service` file gives you (supervision, journal logging, cgroup
resource limits, clean process-tree teardown, scheduling) without writing a unit
file. Where `./script.sh &`, `nohup`, `screen`, or a cron line leave you with a
bare, unsupervised process tied to your session, `systemd-run` leaves behind a
managed unit you can `systemctl status` and `journalctl -u`. That single
difference is the entire value.

The mental model:

> **systemd-run ≈ `nohup` + `cron` + `nice`/`ulimit` + `setsid` + a throwaway
> `.service` file, collapsed into one command — and what it leaves behind is a
> supervised, inspectable unit instead of a loose process.**

It has been in systemd for many years, so it is available on **RHEL 7, 8, 9, 10**
and every other systemd distro. (A handful of *individual flags* are newer; those
are called out throughout.)

---

## 2. What you get for free, mapped to the old-way pain

| Capability | Old-way equivalent | What systemd-run gives you |
|---|---|---|
| Survives logout / SSH drop | `nohup`, `screen`, `tmux` | Process is parented by PID 1, not your shell |
| Logging | `> log 2>&1` by hand | stdout/stderr captured in the journal, tagged by unit |
| Resource limits | `ulimit`, `nice` (leaky, per-process) | cgroup limits covering the command **and all children** |
| Scheduling | `crontab`, `at` | `--on-calendar` / `--on-active` one-liners, with logging |
| Run as another user | `su -c`, `sudo -u` | `--uid=`/`--gid=` with a proper session/cgroup |
| Sandboxing | hand-rolled, fragile | any `systemd.exec` directive via `-p` |
| Clean kill | `kill` + hunt for orphans | stop the unit → whole cgroup torn down |
| Inspect later | remember the PID | `systemctl status <unit>` from any session |

---

## 3. Anatomy of the command and the two modes

```
systemd-run [OPTIONS...] COMMAND [ARGS...]
systemd-run [OPTIONS...] --unit=NAME [PROPERTY=VALUE...]
```

There are two execution modes, and choosing correctly matters:

**`--service` (default):** the command runs **asynchronously**, forked off PID 1,
in a **clean, detached** environment. `systemd-run` returns as soon as the job has
*started*. This is what you want for fire-and-forget background work that should
outlive your session.

**`--scope`:** the command runs **synchronously** in **your current session and
context** (it inherits your environment, cwd, etc.), but is still wrapped in a
cgroup-managed unit. `systemd-run` blocks until it finishes. This is what you want
when you need the caller's environment or want to cap an interactive command.

A first taste of each:

```bash
# Service: detached, named, survives logout
systemd-run --unit=myjob /usr/local/bin/myjob.sh

# Scope: runs here, in my context, blocks until done, but cgroup-managed
systemd-run --scope -p MemoryMax=2G /usr/local/bin/myjob.sh
```

> **Gotcha (service mode):** in `--service` mode the first argument **must be an
> absolute path** (`/usr/local/bin/myjob.sh`, not `myjob.sh`). In `--scope` mode a
> relative path works because it runs in your shell's context.

---

## 4. Your first runs

```bash
# Simplest possible — runs `env`, logs to the journal under an auto-named unit
systemd-run /usr/bin/env
# → "Running as unit: run-19945.service"

# Name it so you can find it later
systemd-run --unit=backup-now /usr/local/bin/backup.sh

# Check on it
systemctl status backup-now
journalctl -u backup-now -f          # follow its output live

# Stop it (tears down the whole process tree via cgroup)
systemctl stop backup-now
```

---

## 5. Running scripts that need arguments, variables, and config

This is the section that trips people up, because **`systemd-run` is not a
shell.** Everything below follows from that one fact.

### 5.1 Passing arguments to your script

Arguments just go after the command. Everything after the first non-option
argument becomes the launched command line:

```bash
systemd-run --unit=sync /usr/local/bin/sync.sh --source /data --dest /backup --verbose
```

Here `--source`, `/data`, etc. are passed to `sync.sh`, **not** interpreted by
`systemd-run`, because they come after the command. (Put any `systemd-run` options
*before* the command.)

### 5.2 Setting environment variables — `--setenv` / `-E`

This is the key one. You **cannot** do the shell habit `FOO=bar systemd-run
cmd` — that sets `FOO` for the *`systemd-run` process itself*, which then runs the
command in a **clean** environment that does not include it. To set a variable
*for the command*, use `--setenv` (repeatable):

```bash
systemd-run --unit=report \
  --setenv=DB_HOST=db01.internal \
  --setenv=DB_PORT=5432 \
  --setenv=LOG_LEVEL=debug \
  /usr/local/bin/generate-report.sh
```

Each `--setenv=NAME=VALUE` adds one variable. `-E` is the short form:

```bash
systemd-run -E API_BASE=https://api.internal -E TIMEOUT=30 /usr/local/bin/fetch.sh
```

**Pass a variable through from your current shell:** if you omit `=VALUE`, the
value of the same-named variable in *your* environment is forwarded:

```bash
export DEPLOY_TOKEN_PATH=/etc/deploy/token
systemd-run --setenv=DEPLOY_TOKEN_PATH /usr/local/bin/deploy.sh
#                     ^ no =value → takes the value from the caller's env
```

### 5.3 Loading many variables from a file — `EnvironmentFile=`

For a whole config file of `KEY=value` lines, use the `EnvironmentFile=`
property rather than a long stack of `--setenv` flags:

```bash
systemd-run --unit=etl \
  -p EnvironmentFile=/etc/etl/etl.env \
  /usr/local/bin/etl.sh
```

`/etc/etl/etl.env` is plain `KEY=value` lines (the same format systemd services
use). Prefix the path with `-` (`-p EnvironmentFile=-/etc/etl/etl.env`) to make
it optional — no error if the file is missing.

### 5.4 Setting the working directory

Your script may expect to run from a particular directory. Three ways, in order
of portability:

```bash
# Most portable — works on RHEL 8 and 9 (it's just a unit property)
systemd-run -p WorkingDirectory=/srv/app /usr/local/bin/app.sh

# Convenience flag (newer systemd — RHEL 9; maps to the property above)
systemd-run --working-directory=/srv/app /usr/local/bin/app.sh

# "Same directory as where I'm standing now" — systemd v240+ (NOT RHEL 8)
systemd-run --same-dir /usr/local/bin/app.sh
```

> **RHEL 8 note:** `--same-dir`/`-d` was added in systemd v240; RHEL 8 ships 239,
> so it isn't there. Use `-p WorkingDirectory=$PWD` instead. The `-p
> WorkingDirectory=` property form works everywhere and is the safe default.

### 5.5 The big one: it's not a shell, so wrap shell features in `bash -c`

Pipes, redirects, globs, `&&`, `||`, `;`, command substitution `$(...)`, and
brace expansion are **shell features**. `systemd-run` has no shell, so they do
**not** work directly — and worse, your *calling* shell will grab them first. For
example:

```bash
# WRONG — the > redirect is applied by YOUR shell to systemd-run's output,
# not to the command inside the unit
systemd-run /usr/local/bin/dump.sh > /backup/dump.sql
```

When you need shell behavior *inside the unit*, invoke a shell explicitly and
pass the whole pipeline as a single quoted string to `-c`:

```bash
# RIGHT — bash runs inside the unit and handles the redirect/pipe there
systemd-run --unit=dump /bin/bash -c '/usr/local/bin/dump.sh > /backup/dump.sql 2>&1'

systemd-run --unit=pipeline /bin/bash -c \
  'tar czf - /data | ssh backup@nas "cat > /vol/data.tgz"'

systemd-run --unit=cleanup /bin/bash -c \
  'find /var/tmp -type f -mtime +30 -delete && echo done'
```

The rule: **one command, no shell metacharacters → run it directly. Anything with
a pipe, redirect, glob, `&&`, or `$(...)` → wrap it in `/bin/bash -c '...'`.**

### 5.6 systemd's own `$VARIABLE` expansion (a subtle trap)

systemd itself expands `$NAME` and `${NAME}` in the command line, using the
*unit's* environment (the variables you set with `--setenv`, **not** your shell's
variables). So a literal `$` you want passed through must be **doubled** (`$$`):

```bash
# Want the shell inside the unit to see a literal $$ (its own PID)?  Double it:
systemd-run /bin/bash -c 'echo my pid is $$'
#   systemd collapses $$ → $, bash then expands $ -> ... be careful here.
```

To pass a literal dollar sign through systemd untouched, write `$$`. On **systemd
254+** you can instead disable systemd's expansion entirely with
`--expand-environment=no` — but that flag does **not** exist on RHEL 8/9 (239/252),
so on those releases the `$$`-doubling rule is what you rely on.

### 5.7 Secrets: do NOT put them in `--setenv`

A variable set with `--setenv` is visible in the unit's metadata — anyone who can
run `systemctl show <unit>` or read the journal can see it. **Never pass
passwords, tokens, or keys this way.**

The right tool is systemd **credentials**, which are passed to the process out of
band and not exposed in unit metadata:

```bash
# RHEL 9 (systemd 252) and newer
systemd-run --unit=restore \
  -p LoadCredential=dbpass:/etc/secrets/db-password \
  /usr/local/bin/restore.sh
# inside restore.sh, read it from:  $CREDENTIALS_DIRECTORY/dbpass
```

> **RHEL note:** `LoadCredential=`/`SetCredential=` require the credentials
> infrastructure (systemd 247+), so this works on **RHEL 9** but **not RHEL 8**.
> On RHEL 8, fall back to `-p EnvironmentFile=` pointing at a root-only `0600`
> file, and accept that env vars are slightly more exposed than credentials.

---

## 6. Watching, waiting, and capturing output

By default a `--service` job runs in the background and its output goes to the
**journal, not your terminal** — surprising the first time. Control that with:

```bash
# Wait for it to finish and propagate its exit code (great in scripts)
systemd-run --wait --unit=job /usr/local/bin/job.sh
echo "job exited with: $?"

# Inherit stdin/stdout/stderr so it works in a pipeline (implies --wait)
echo "input" | systemd-run --pipe /usr/local/bin/filter.sh | sort

# Interactive — attach a real PTY (for things that expect a terminal)
systemd-run --pty /usr/local/bin/interactive-tool.sh

# Newer convenience: --shell / -S  ==  --pty --same-dir --wait --collect (a root shell in a unit)
systemd-run --shell        # (newer systemd; handy on RHEL 9+)
```

- `--wait` — block until done, show runtime stats, return the command's exit code.
- `--pipe` / `-P` — wire stdio through, for use inside pipelines.
- `--pty` / `-t` — allocate a pseudo-terminal for interactive programs.

---

## 7. Cleaning up: failed units linger unless you say otherwise

By default, a transient unit that **fails** stays in memory in a `failed` state
until you clear it — so repeated failing runs accumulate clutter:

```bash
systemctl list-units --failed         # see leftover failed transient units
systemctl reset-failed run-1234.service   # clear one manually
```

Avoid the buildup with `--collect` / `-G`, which unloads the unit when it
completes **even if it failed**:

```bash
systemd-run --collect --wait --unit=probe /usr/local/bin/probe.sh
```

Make `--collect` a habit for one-off jobs you don't need to inspect after the
fact.

---

## 8. Resource control (the cgroup superpower)

This is where `systemd-run` decisively beats `nice`/`ulimit`: limits are applied
to the **cgroup**, so they cover the command *and every child it spawns*, and
they are actually enforced.

```bash
# Cap memory at 4 GiB and CPU at half a core — for the whole process tree
systemd-run -p MemoryMax=4G -p CPUQuota=50% --unit=batch /usr/local/bin/batch.sh

# Soft pressure (reclaim above 2G) + hard ceiling, plus IO weight and CPU shares
systemd-run \
  -p MemoryHigh=2G \
  -p MemoryMax=3G \
  -p CPUWeight=20 \
  -p IOWeight=20 \
  --unit=nightly-reindex /usr/local/bin/reindex.sh
```

Commonly useful properties:

| Property | Effect |
|---|---|
| `MemoryMax=` | Hard memory ceiling; OOM-kills the cgroup if exceeded |
| `MemoryHigh=` | Soft limit; throttles/reclaims above it (cgroup v2 only) |
| `CPUQuota=` | Absolute CPU cap, e.g. `50%` = half a core, `200%` = two cores |
| `CPUWeight=` | Relative CPU share under contention (default 100) |
| `IOWeight=` | Relative block-IO share |
| `TasksMax=` | Cap on number of processes/threads |

> **RHEL 8 vs 9:** RHEL 9 defaults to the **unified cgroup v2** hierarchy, where
> all of the above (including `MemoryHigh=`) behave fully. RHEL 8 defaults to
> **cgroup v1**, where the basics (`MemoryMax`, `CPUQuota`) work but some v2-only
> knobs (like `MemoryHigh`) do not. If you lean heavily on resource control, the
> story is cleaner on RHEL 9.

---

## 9. Sandboxing an untrusted or messy script, ad hoc

Any directive from `systemd.exec(5)` can be applied with `-p`, so you can confine
a script without writing a unit file:

```bash
systemd-run \
  -p PrivateTmp=yes \
  -p ProtectHome=yes \
  -p ProtectSystem=strict \
  -p ReadWritePaths=/srv/app/data \
  -p NoNewPrivileges=yes \
  -p DynamicUser=yes \
  --unit=sandboxed /usr/local/bin/third-party-thing.sh
```

| Property | Effect |
|---|---|
| `PrivateTmp=yes` | Private `/tmp` and `/var/tmp`, wiped after |
| `ProtectHome=yes` | `/home`, `/root`, `/run/user` made inaccessible |
| `ProtectSystem=strict` | Entire filesystem read-only except explicit paths |
| `ReadWritePaths=` | Carve out specific writable paths under `strict` |
| `NoNewPrivileges=yes` | Block privilege escalation (setuid, etc.) |
| `DynamicUser=yes` | Run as an **ephemeral** user created for the run and destroyed after |

`DynamicUser=yes` is a nice tie-in to declarative user management: the process
gets a transient, locked-down identity with no account to allocate or clean up.

---

## 10. Running as another user

```bash
# A one-off database dump as the postgres user, properly sessioned
systemd-run --uid=postgres --unit=pgdump \
  /bin/bash -c '/usr/bin/pg_dump mydb > /backup/mydb.sql'

systemd-run --uid=nginx --gid=nginx /usr/local/bin/cache-warm.sh
```

Unlike `su -c` / `sudo -u`, the process lands in its own cgroup and journal unit,
so it's supervised and inspectable.

---

## 11. Ad-hoc scheduling without touching crontab

`systemd-run` can create a transient **timer** that fires once (or repeatedly),
giving you cron-like scheduling with journald logging and `systemctl status`:

```bash
# Run once, 2 hours from now
systemd-run --on-active=2h --unit=delayed-cleanup /usr/local/bin/cleanup.sh

# Run once tonight at 03:00 (calendar syntax)
systemd-run --on-calendar="*-*-* 03:00:00" --unit=nightly /usr/local/bin/nightly.sh

# Run 15 minutes after every boot
systemd-run --on-boot=15min --unit=post-boot-check /usr/local/bin/check.sh

# Repeating: every 6 hours after the unit last activated
systemd-run --on-unit-active=6h --unit=poller /usr/local/bin/poll.sh

# Set a property on the *timer* unit specifically (vs the service)
systemd-run --on-calendar=hourly --timer-property=AccuracySec=1min \
  --unit=hourly-thing /usr/local/bin/thing.sh
```

| Flag | Meaning |
|---|---|
| `--on-active=` | Relative to now |
| `--on-boot=` | Relative to system boot |
| `--on-startup=` | Relative to systemd (PID 1) startup |
| `--on-unit-active=` | Relative to the service's last activation (for repeats) |
| `--on-unit-inactive=` | Relative to the service's last deactivation |
| `--on-calendar=` | Wall-clock calendar expression (like `OnCalendar=`) |

> **Critical caveat:** transient units live in `/run` and **do not survive a
> reboot.** `--on-calendar` via `systemd-run` is perfect for "later today," but if
> you need a schedule that persists across reboots **forever**, write a real
> `.timer` unit (or keep the cron job). Don't mistake transient timers for
> permanent infrastructure.

---

## 12. Real-world admin recipes

**Long migration/rsync over SSH that must survive disconnect:**
```bash
systemd-run --unit=migrate-data --collect \
  /usr/local/bin/rsync-migration.sh
# close your laptop; reconnect later and:
journalctl -u migrate-data -f
```

**Bound a runaway batch job so it can't starve production:**
```bash
systemd-run --unit=heavy-import -p MemoryMax=6G -p CPUQuota=150% --collect \
  /usr/local/bin/import.sh /data/incoming/*.csv
```

**Big dnf transaction over a flaky connection:**
```bash
systemd-run --unit=mass-update --collect \
  /bin/bash -c 'dnf -y update && dnf -y autoremove'
```

**Nightly one-off that doesn't deserve a permanent cron entry:**
```bash
systemd-run --on-calendar="*-*-* 02:30:00" --unit=tonight-only --collect \
  /usr/local/bin/one-time-reindex.sh
```

**Capped, sandboxed run of a vendor script you don't fully trust:**
```bash
systemd-run --unit=vendor --collect \
  -p DynamicUser=yes -p PrivateTmp=yes -p ProtectSystem=strict \
  -p MemoryMax=1G -p CPUQuota=50% \
  /opt/vendor/run.sh
```

**Script with full config: args + env file + working dir + waited exit code:**
```bash
systemd-run --unit=etl-run --collect --wait \
  -p WorkingDirectory=/srv/etl \
  -p EnvironmentFile=/etc/etl/etl.env \
  --setenv=RUN_DATE="$(date +%F)" \
  /usr/local/bin/etl.sh --full --target warehouse
echo "ETL exit code: $?"
```
*(Note `RUN_DATE="$(date +%F)"` — the `$(...)` is expanded by **your** shell
before `systemd-run` runs, which is fine and intended here; the result is passed
as a literal value via `--setenv`.)*

**On a remote host or inside a container/machine:**
```bash
systemd-run --host=user@server01 --unit=remote-job /usr/local/bin/job.sh
systemd-run --machine=mycontainer --unit=in-container /usr/local/bin/job.sh
```

---

## 13. Gotchas and limitations

- **Service mode needs an absolute path.** `systemd-run myscript.sh` fails;
  use `/usr/local/bin/myscript.sh`. (Scope mode allows relative paths.)
- **It is not a shell.** Pipes, redirects, globs, `&&`, `$(...)` need a
  `/bin/bash -c '...'` wrapper (§5.5).
- **Output goes to the journal by default**, not your terminal. Use
  `--wait`/`--pipe`/`--pty` when you want to see it directly.
- **Transient units don't survive reboot.** Great for "now" and "later today";
  for permanent schedules write a real `.timer`/`.service`.
- **Failed units linger** until cleared; use `--collect` or `systemctl
  reset-failed`.
- **Secrets don't belong in `--setenv`** — they show in unit metadata. Use
  `LoadCredential=` (RHEL 9+) or a `0600` `EnvironmentFile=`.
- **Don't wrap trivial foreground commands in it.** If a job is short and you're
  watching it, just run it — `systemd-run` is for detached, long-lived,
  resource-sensitive, or scheduled work.
- **RHEL 8 vs 9 flag/feature gaps:** `--same-dir` (v240), `--expand-environment=`
  (v254), and `LoadCredential=` (v247) are **not** on RHEL 8 (systemd 239);
  cgroup v2 resource control is fuller on RHEL 9 (252). Prefer the `-p
  PropertyName=` property forms when you want one command line that works on both.

---

## 14. Quick reference

### Modes
```
(default)   --service   async, clean/detached context, absolute path required
--scope                 sync, caller's context, relative path OK
```

### Most-used options
```
--unit=NAME              name the unit (otherwise auto-named run-XXXX)
-p, --property=K=V       any unit property (resource limits, sandboxing, env)
-E, --setenv=NAME=VALUE  set an env var (repeatable; omit =VALUE to pass through)
--working-directory=DIR  set cwd  (or: -p WorkingDirectory=DIR  — portable)
--same-dir, -d           cwd = caller's cwd            (systemd v240+, not RHEL 8)
--uid= / --gid=          run as user/group
--nice=N                 nice level
--wait                   block, show stats, return command's exit code
--pipe, -P               wire stdio through (for pipelines)
--pty, -t                allocate a PTY (interactive)
--collect, -G            unload the unit after exit, even on failure
--on-active= / --on-calendar= / --on-boot=   transient timer scheduling
--host= / --machine=     run on a remote host / in a container
```

### Inspect & control
```
systemctl status NAME            # state and recent log lines
journalctl -u NAME [-f]          # full output (follow with -f)
systemctl stop NAME              # stop; tears down whole cgroup
systemctl list-units --failed    # find leftover failed transient units
systemctl reset-failed NAME      # clear a failed unit
```

### The two rules that prevent most mistakes
```
1. Absolute path in --service mode; wrap shell syntax in /bin/bash -c '...'.
2. Variables for the command go in --setenv / EnvironmentFile, never as
   FOO=bar before the command. Secrets go in credentials, not --setenv.
```

---

*Flag behavior verified against `systemd-run(1)`. Version-gated flags are noted
inline; unannotated features work on RHEL 8 (systemd 239) and RHEL 9 (systemd
252). Resource-control depth assumes cgroup v2 (RHEL 9 default).*
