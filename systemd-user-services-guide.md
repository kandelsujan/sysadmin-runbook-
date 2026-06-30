# systemd User Services (`systemctl --user`): A Sysadmin Companion

*Per-user systemd instances, lingering, and when to use them instead of a system
service with `User=`. Companion to the systemd Service Administration reference.*

---

## 1. Two different things people constantly conflate

There are **two separate ideas** that both involve "running a service as a
particular user," and keeping them straight is the whole point of this document.

**`User=acme` in a system unit** (covered in the main service-admin guide): the
*system* systemd — PID 1, owned by root — runs the service but drops privileges
to `acme`. It lives in `/etc/systemd/system/`, starts at boot, and is administered
by root. The user `acme` does not control it.

**`systemctl --user`**: a *completely separate systemd instance that runs per
logged-in user*, owned by that user, with no root involvement. Each user gets
their own `systemd --user` process (PID-1-like, but for their session) that
manages their own units. The user creates, starts, and enables services entirely
within their own account — no sudo, no root.

| | System unit + `User=` | User instance (`--user`) |
|---|---|---|
| Managed by | root / PID 1 | the user's own `systemd --user` |
| Who can control it | root (admin) | the user themselves |
| Unit file location | `/etc/systemd/system/` | `~/.config/systemd/user/` |
| Starts at boot | Yes | Only if **lingering** is on (§5) |
| Needs sudo to manage | Yes | No |
| Can grant capabilities / bind low ports | Yes | **No** |
| Drops to which user | whatever `User=` says | always the owning user |

The "user-specific services" feature you were remembering is the second one, and
it is alive and well.

---

## 2. The `--user` workflow

Every command gains `--user`, and you run them **as that user, without sudo**:

```bash
systemctl --user start   myapp
systemctl --user stop    myapp
systemctl --user restart myapp
systemctl --user enable --now myapp
systemctl --user disable --now myapp
systemctl --user status  myapp
systemctl --user list-units --type=service
systemctl --user daemon-reload          # after editing a user unit

# Their own journal (only their user units; no root needed)
journalctl --user -u myapp -f
```

There is no `enable`/`start` distinction to relearn — it works exactly like the
system instance, just scoped to the user.

---

## 3. Where user units live

```
~/.config/systemd/user/        the user's OWN units          (highest priority)
/etc/systemd/user/             units an ADMIN provides to ALL users
/usr/lib/systemd/user/         vendor-provided user units    (lowest priority)
```

The middle path is useful to you as an admin: dropping a unit in
`/etc/systemd/user/` makes it available to *every* user's instance, which they can
then `systemctl --user enable` for themselves.

---

## 4. What a user unit looks like

Almost identical to a system unit, with two meaningful differences: **no
`User=`/`Group=`** (it always runs as the owning user — that is the entire point),
and the `[Install]` target is typically **`default.target`**, not
`multi-user.target`.

```ini
# ~/.config/systemd/user/sync.service
[Unit]
Description=Personal sync job

[Service]
Type=simple
ExecStart=%h/bin/sync.sh
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=default.target
```

`%h` expands to the user's home directory, which is convenient since user units
usually point at things under `$HOME`. Most `[Service]` directives work the same;
the privilege-related ones (§8) do not.

---

## 5. Lingering — the concept everyone misses

**By default, a user's `systemd --user` instance only exists while they have an
active login session.** Log out, and the instance — and every service it was
running — stops. A user who enables a service and then logs off will find it dead.

The fix is **lingering**, which you enable (as admin, via `loginctl`):

```bash
loginctl enable-linger username      # user instance starts at boot, persists with no session
loginctl disable-linger username     # back to "only while logged in"
loginctl user-status username        # shows "Linger: yes/no" among other things
loginctl list-users                  # all users with running instances / linger
```

With linger on, that user's instance is started at **boot** and kept alive
independent of any login, so their enabled `--user` services behave like real
background daemons. This is the single knob that turns "user services" from a
session-only convenience into something that survives reboots and logouts.

> A user can often enable linger for *themselves* (`loginctl enable-linger` with
> no argument) depending on the polkit policy, but as the admin you can always set
> it. If a user reports "my enabled user service isn't running after reboot,"
> linger is almost always the answer.

---

## 6. The gotcha: managing user services as admin / over SSH

This catches everyone. If you try to manage a user's services from a root shell,
a script, or a non-login SSH context, you get:

```
Failed to connect to bus: No such file or directory
```

The reason: `systemctl --user` talks to the user's session bus, which needs
`XDG_RUNTIME_DIR` (`/run/user/<uid>`) set and the per-user bus reachable — and a
bare `sudo -u user` shell has neither.

Ways to make it work:

```bash
# Cleanest: get a real user session/login shell
machinectl shell username@

# Or set the runtime dir explicitly when invoking as that user
sudo -u username XDG_RUNTIME_DIR=/run/user/$(id -u username) \
  systemctl --user status myapp

# Run a command in their context as a transient user-instance unit
sudo -u username XDG_RUNTIME_DIR=/run/user/$(id -u username) \
  systemd-run --user --unit=adhoc /home/username/bin/task.sh
```

Note that **linger guarantees `/run/user/<uid>` exists persistently**, which also
makes this admin-side management reliable — another reason to enable it for users
whose services you may need to touch.

---

## 7. Resource control and the RHEL 8 vs 9 caveat

You can set `MemoryMax=`, `CPUQuota=`, `TasksMax=`, etc. in user units, but
whether they are *actually enforced* depends on **cgroup v2 delegation** to the
user instance:

- **RHEL 9** defaults to unified cgroup v2, where the system delegates a cgroup
  subtree to each user instance, so resource limits in `--user` units work
  properly.
- **RHEL 8** defaults to cgroup v1, where this delegation is limited, so a
  `MemoryMax=` in a `--user` unit may be silently ignored.

So: if you need *enforced* resource caps on a user's workload on **RHEL 8**, run it
as a **system service with `User=`** instead, where the system instance applies
the cgroup limits directly. On RHEL 9 the user-instance route is fine.

---

## 8. What user instances cannot do

A user instance has only the privileges of the user — so several things from the
system-service toolkit are simply unavailable:

- **No privileged ports.** `AmbientCapabilities=CAP_NET_BIND_SERVICE` won't help;
  a user instance can't grant capabilities it doesn't have. Binding `< 1024`
  needs a system service.
- **No `DynamicUser=`**, no `User=`/`Group=` switching — it's always the one user.
- **No capability grants** generally (`CapabilityBoundingSet=` can only *reduce*).
- **Weaker isolation guarantees** for some `Protect*` namespacing directives that
  expect system-service privileges.

If the request needs any of those, it belongs in a system unit, not `--user`.

---

## 9. User timers (cron replacement, per user)

User instances support timers too — a user can schedule their own jobs without a
crontab or admin involvement:

```ini
# ~/.config/systemd/user/backup.timer
[Unit]
Description=Nightly personal backup

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now backup.timer
systemctl --user list-timers
```

`Persistent=true` requires linger to be useful across reboots (otherwise the
instance isn't running to catch up the missed run).

---

## 10. Quick decision guide: system `User=` vs `--user`

**Use a system service with `User=`** (the main guide's approach) when:

- *You* provide the service on behalf of the user — it's infrastructure.
- It must start at boot regardless of who's logged in.
- It needs enforced resource limits on **RHEL 8**.
- It needs a privileged port, capabilities, or `DynamicUser=`.
- It must be administered/owned by root.

This is the right default for almost anything a user "requests" that you then run
*for* them.

**Use `systemctl --user`** when:

- The thing genuinely belongs to the user and lives in their space — personal
  automation, a developer's own long-running tool.
- The user should manage it themselves without sudo.
- You're on a multi-user box and don't want to hand-write a system unit per
  person.
- (Pair with `loginctl enable-linger` so it behaves like a real daemon.)

> **Rule of thumb:** if it should show up in *your* `systemctl list-units` as
> something you own and boot brings up → system unit with `User=`. If the user
> should `systemctl --user` it themselves → user unit + linger.

---

## 11. Quick reference

### Commands
```
systemctl --user start|stop|restart|enable --now|disable --now UNIT
systemctl --user status UNIT
systemctl --user list-units --type=service
systemctl --user list-timers
systemctl --user daemon-reload          # after editing a user unit
journalctl --user -u UNIT [-f]

loginctl enable-linger  USER            # user instance starts at boot, survives logout
loginctl disable-linger USER
loginctl user-status    USER            # check Linger: yes/no
loginctl list-users
```

### Managing a user's services as admin
```
machinectl shell username@
# or:
sudo -u USER XDG_RUNTIME_DIR=/run/user/$(id -u USER) systemctl --user ...
```

### File locations
```
~/.config/systemd/user/      user's own units        (highest priority)
/etc/systemd/user/           admin-provided to all users
/usr/lib/systemd/user/       vendor units            (lowest priority)
```

### Key differences from a system unit
```
- No User=/Group=  (always runs as the owning user)
- [Install] WantedBy=default.target  (not multi-user.target)
- %h available for the user's home
- No privileged ports / capabilities / DynamicUser=
- Resource limits enforced only with cgroup v2 delegation (RHEL 9; limited on RHEL 8)
- Stops on logout UNLESS loginctl enable-linger is set
```

### The two things that prevent most mistakes
```
1. Enabled user service not running after reboot/logout?  → loginctl enable-linger
2. "Failed to connect to bus" managing it as admin?       → set XDG_RUNTIME_DIR
                                                             (or use machinectl shell)
```

---

*Behavior described applies to RHEL 8 (systemd 239) and RHEL 9 (systemd 252). The
main version-sensitive difference is cgroup v2 delegation for user-instance
resource control, which is the RHEL 9 default and limited on RHEL 8.*
