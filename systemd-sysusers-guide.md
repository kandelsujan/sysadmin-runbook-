# systemd-sysusers: A Practical Guide for Linux Administrators

*Declarative system user and group management for RHEL 8/9 and beyond*

---

## 1. What it is, in one paragraph

`systemd-sysusers` creates **system users and groups** from small declarative
configuration files instead of imperative commands. Rather than running
`useradd`/`groupadd` from a script and hoping it only runs once, you *describe*
the accounts you want in a `.conf` file, and systemd makes the local user
database match that description. It is **additive and idempotent**: it creates
what is missing and does nothing to what already exists, so it can run safely at
package install time, at every boot, and during offline image builds — as many
times as you like, with no duplication and no errors on re-run.

It has been part of systemd since version 215, so it is present and usable on
**RHEL 7, 8, 9, and 10**, Fedora, Debian/Ubuntu, SUSE, Arch — anything with
systemd.

---

## 2. Why use it (the case against `useradd` in scripts)

The traditional way to provision a service account is a line in an RPM
scriptlet, a Kickstart `%post`, or an Ansible task:

```bash
getent group acme >/dev/null || groupadd -r acme
getent passwd acme >/dev/null || useradd -r -g acme -d /var/lib/acme \
    -s /usr/sbin/nologin acme
```

Every line of that is defensive boilerplate working around the fact that
`useradd` is imperative: it errors if the account exists, so you guard it with
`getent`; it runs once at a specific moment, so a re-provision or a rebuilt
image silently skips it; and the definition lives *in a script*, divorced from
the software that needs it.

The sysusers equivalent is a single declarative line that carries no "does it
already exist?" logic because the tool handles that intrinsically:

```
# /usr/lib/sysusers.d/acme.conf
u  acme  -  "ACME collector"  /var/lib/acme  /usr/sbin/nologin
```

| Property | `useradd` in a script | `sysusers.d` file |
|---|---|---|
| Idempotent | No (must guard with `getent`) | Yes, intrinsically |
| Re-runnable safely | No | Yes (install + every boot) |
| Lives with the software | No (in a script) | Yes (in the package) |
| Locked / `nologin` by default | Only if you remember the flags | Yes, by default |
| Version-controlled & reviewable | Awkward | Naturally |
| Works in offline image build | Needs a chroot + scriptlet run | `--root=` applies directly |

The mental shift: you stop writing **instructions** ("create this account") and
start declaring **desired state** ("this account should exist"). That is the
same shift behind `tmpfiles.d`, `repart.d`, and the rest of the modern systemd
toolkit.

---

## 3. Where the files live

Configuration is read from three directories, in **descending** order of
priority:

| Directory | Owner | Purpose |
|---|---|---|
| `/etc/sysusers.d/` | Local administrator | Your overrides and site policy — highest priority |
| `/run/sysusers.d/` | Runtime | Volatile, generated at runtime |
| `/usr/lib/sysusers.d/` | Packages (RPMs) | Vendor/software definitions — lowest priority |

Files are named `<name>.conf` (e.g. `nginx.conf`, or `package-part.conf` when
you want a piece that is easy to override independently).

**Precedence rules worth knowing:**

- A file in `/etc/sysusers.d/` with the **same filename** as one in
  `/usr/lib/sysusers.d/` completely **replaces** it. This is how you override a
  vendor definition.
- Across *different* filenames, all files are merged, processed in
  **lexicographic order of filename** regardless of directory. If two files
  define the same user, the one whose filename sorts earliest wins, and later
  duplicates are logged as warnings.
- To **disable** a vendor file entirely, symlink the same filename to
  `/dev/null` in `/etc/sysusers.d/`:

  ```bash
  ln -s /dev/null /etc/sysusers.d/unwanted-vendor.conf
  ```

For an administrator managing a fleet, the practical takeaway is: **your site
policy goes in `/etc/sysusers.d/`** (pushed by Ansible/config management),
**software you package puts its files in `/usr/lib/sysusers.d/`**.

---

## 4. The file format

One line per entry, six whitespace-separated columns. Blank lines and lines
starting with `#` are ignored.

```
#Type  Name    ID                  GECOS              Home            Shell
u      acme    -                   "ACME collector"   /var/lib/acme   /usr/sbin/nologin
g      acmenet -
m      acme    acmenet
r      -       300-399
```

The meaning of columns 3–6 **changes depending on the Type** in column 1, which
is the most common source of confusion. The table below shows what each column
means per type:

| Type | Col 2 (Name) | Col 3 (ID) | Cols 4–6 |
|---|---|---|---|
| `u` | user name | UID spec (see §6) | GECOS, Home, Shell |
| `g` | group name | GID spec | unused (`-`) |
| `m` | **user** name | **group** name to add them to | unused (`-`) |
| `r` | `-` | range `FROM-TO` | unused (`-`) |

**Name rules:** only `a-z A-Z 0-9 _ -`, the first character must be a letter or
`_` (not a digit or `-`), and the name must be 1–31 characters.

Quote the GECOS field if it contains spaces. It must not contain colons. Set any
unused field to `-`.

---

## 5. The four types in detail

### `u` — create a user (and its group)

```
u  acme  -  "ACME collector"  /var/lib/acme  /usr/sbin/nologin
```

Creates a system user **and** a matching primary group of the same name (unless
the ID column specifies a different group). The account is created **disabled**
— an invalid password is set, so password logins are not possible.

> **Version note for RHEL 8/9:** newer systemd (v257+, i.e. RHEL 10 and Fedora,
> *not* RHEL 8/9) supports `u!` to create a *fully locked* account, which also
> blocks non-password authentication like SSH keys. On RHEL 8/9 you only have
> plain `u`. In practice this is fine: a system user with a `/usr/sbin/nologin`
> shell and an invalid password is not a usable login regardless, which is the
> standard RHEL posture.

### `g` — create a group only

```
g  acmenet  -
```

Use this when you need a shared group that is not tied to a single user — for
example a group several daemons or admins belong to. Remember that `u` already
creates a matching group, so you only need `g` for *additional* groups.

### `m` — add an existing user to a group (membership)

```
m  acme  acmenet
```

Adds user `acme` as a **supplementary** member of group `acmenet`. It creates no
new account and never changes the user's *primary* group. Both the user and the
group must exist — either already on the system, or created by `u`/`g` lines in
the same configuration set (order within and across files does not matter;
systemd resolves the whole set together).

This is the clean, declarative replacement for `usermod -aG` in a script:

```
m  prometheus  systemd-journal     # let an exporter read the journal
m  alice        libvirt            # let an admin manage VMs without sudo
```

### `r` — reserve an allocation range

```
r  -  300-399
```

Adds a UID/GID range to the pool that auto-allocation (`-` in the ID field)
draws from. If no `r` line exists anywhere, a compiled-in default range is used.
Both UIDs and GIDs are allocated from the **same** pool, so a user and its
like-named group tend to get the same number. More on why this matters in §8.

---

## 6. The ID column — every form

For `u` and `g` lines, the ID column is flexible and worth knowing fully:

| Value | Meaning |
|---|---|
| `-` | **Auto-allocate** from the system range. Recommended default. |
| `999` | Pin this exact UID (the group gets the same GID if free). |
| `999:998` | Pin UID **and** GID independently. |
| `999:acmenet` | Pin the UID; use existing group `acmenet` as primary group. |
| `-:acmenet` | Auto-allocate UID; use existing group `acmenet` as primary. |
| `/var/lib/acme` | Inherit the UID/GID that **owns that path**. |

The path form (`/var/lib/acme`) is niche but elegant: it is how you adopt the
correct ownership of files left behind by a previous install, or match a SUID
binary's owner, without hardcoding a number.

> Never use `65535` or `4294967295` — they are reserved placeholder values.

---

## 7. Defaults you get for free

When you leave fields as `-`, sysusers fills in sensible, secure defaults:

- **Shell:** `/usr/sbin/nologin` (except for UID 0, which gets `/bin/sh`).
- **Home:** the root directory `/` if unset. It is recommended **not** to set a
  home directory unless the software genuinely needs one — and note that
  sysusers only writes the home path into the *user database*; it does **not
  create the directory**. Creating it is `tmpfiles.d`'s job (see §13).
- **Password:** invalid / disabled. The account cannot be used for password
  login.

This "locked-down by default" behavior is a real advantage: with `useradd` you
have to *remember* `-r -s /usr/sbin/nologin` and lock the password; with
sysusers, the secure outcome is the default.

---

## 8. Allocation, ranges, and the fleet problem

When you auto-allocate with `-`, systemd picks a number from the system range,
working **top-down** (highest free number first). The bounds come from
`SYS_UID_MIN`/`SYS_UID_MAX` and `SYS_GID_MIN`/`SYS_GID_MAX` in
`/etc/login.defs` — commonly `201–999` on RHEL.

The critical property to understand: **auto-allocation is per-host and
non-deterministic across machines.** The same `acme` user might land on UID 982
on one server and 977 on another, simply depending on what else was installed
first. For a self-contained daemon that never shares files off-box, this is
completely fine and you should prefer `-`.

It becomes a problem the moment a UID crosses a machine boundary:

- **NFS / shared storage** authorizes by *numeric* UID/GID, not by name. If
  `backup-svc` is UID 1451 on the file server but auto-allocated to something
  else on a client, the client gets "permission denied" on files it supposedly
  owns.
- **Backups/archives** restored onto a different host can end up owned by the
  wrong account.

The rule of thumb:

> **Auto-allocate (`-`) accounts that stay on one box. Pin a fixed UID/GID for
> any account whose files or identity cross machines.**

For pinned accounts, choose numbers in a deliberately reserved band and document
it. The `r` type lets you keep local auto-allocations out of territory your
directory service owns:

```
# Keep locally auto-allocated system accounts in 300-399,
# clear of the 10000+ band that SSSD/LDAP hands out.
r  -  300-399
```

### The NSS-bypass caveat (important with LDAP/AD)

`systemd-sysusers` reads and writes `/etc/passwd` and `/etc/group`
**directly**. It does **not** consult NSS, so it cannot see users that exist
only in LDAP, AD, or NIS. Two consequences:

1. It will happily create a *local* `acme` even if an `acme` exists in your
   directory, because it only checked the local files. Choose system-account
   names that cannot collide with directory users.
2. This is by design — system accounts should be local and present before the
   network or SSSD is up. Just be aware that "does this user exist?" means
   "exist *locally*" to sysusers.

A widely recommended naming convention (upstream) is to prefix system accounts
with `_` (e.g. `_acme`) to avoid clashes with human and directory users. Note
that **RHEL's own packages historically do not** follow this (you see `chrony`,
`nginx`, `postgres`), so match whatever convention your environment already
uses — but the `_` prefix is a sound choice for *new* in-house accounts.

---

## 9. When and how it actually runs

Three trigger points, which together make it robust:

1. **At package install (RPM file trigger).** RHEL/Fedora ship an RPM file
   trigger watching `/usr/lib/sysusers.d/`. Dropping a `.conf` into your package
   causes the account to be created automatically on `dnf install` — **no
   `%pre`/`%post` scriptlet needed**.
2. **At every boot.** `systemd-sysusers.service` runs early in boot and applies
   anything still missing. So an image assembled without running scriptlets, or
   a system booted with a freshly-reset `/etc`, self-heals.
3. **On demand**, by running the command yourself (next section).

Because it is idempotent, none of these conflict — running all three over a
machine's life simply converges to the declared state every time.

---

## 10. Operating it: the commands

```bash
# Show what WOULD happen, change nothing — use this in CI / pre-deploy checks
systemd-sysusers --dry-run

# Apply ALL sysusers.d files now
systemd-sysusers

# Apply a single specific file
systemd-sysusers /etc/sysusers.d/site-accounts.conf

# Apply config given inline on the command line (no file)
systemd-sysusers --inline 'u testacct - "Test account"'

# Apply into an offline image / chroot instead of the running system
systemd-sysusers --root=/mnt/newimage

# Show the merged effective configuration from all directories
systemd-sysusers --cat-config

# The boot-time service that self-heals
systemctl status systemd-sysusers
journalctl -u systemd-sysusers          # see what it did / any warnings

# Verify the result
getent passwd acme
getent group  acmenet
```

`--dry-run` is the habit to build: run it in your pipeline before shipping a
file, and a typo'd range or bad ID is caught for free.

---

## 11. Real-world administration use cases

### A. Packaging your own software

The canonical use. Your in-house `acme-collector` RPM ships
`/usr/lib/sysusers.d/acme-collector.conf`. The account is created on install via
the file trigger; your unit file's `User=acme` just works; and a reinstall or an
offline image build both produce the same account with no scriptlet to break.

```
# /usr/lib/sysusers.d/acme-collector.conf
u  acme  -  "ACME collector"  /var/lib/acme  /usr/sbin/nologin
```

(In an RPM spec, declare `%sysusers_create_compat` / the
`sysusers.generate-pre` macros, or simply rely on the file trigger — your
packaging guidelines will specify which.)

### B. Standard fleet-wide accounts

Probably your biggest win. You want identical `deploy`, `backup-svc`, and
`monitoring` accounts on every host. Push one file via Ansible to
`/etc/sysusers.d/` (the admin-override location):

```
# /etc/sysusers.d/site-accounts.conf  — distributed by config management
u  deploy      1450:1450  "Deploy automation"  /var/lib/deploy  /bin/bash
u  backup-svc  1451:1451  "Backup service"     /var/lib/backup  /usr/sbin/nologin
u  monitoring  1452:1452  "Monitoring agent"   /var/lib/monitoring  /usr/sbin/nologin
m  deploy      systemd-journal
```

Pinned UIDs mean `deploy` is 1450 *everywhere*, and the file is idempotent so
your converge step can apply it on every run with zero churn.

### C. UID consistency across NFS

Continuing B: because `backup-svc` is pinned to 1451 on both the NFS server and
every client, file ownership lines up across the mount. This is the clean,
declarative way to guarantee the numeric consistency NFS depends on.

### D. Declarative group membership

The `m` type replaces scattered `usermod -aG` calls:

```
m  prometheus  systemd-journal
m  nginx       acmenet
```

### E. Golden images and reproducible rebuilds

When account definitions live in version-controlled `sysusers.d` files, a host
rebuilt from scratch comes up with byte-identical accounts. There is no "did the
useradd step run?" ambiguity — the file is the source of truth, and it is in
git.

### F. Offline image / chroot builds

```bash
systemd-sysusers --root=/mnt/image
```

Populates `/etc/passwd` and `/etc/group` in a target tree without booting it —
how image builders provision accounts.

---

## 12. Limitations you must design around

This is the single most important section. **sysusers is additive-only.** It
creates what is missing and otherwise does nothing. It will **not**:

- **Modify an existing account.** If `acme` already exists as UID 1200 and your
  file says `1500`, it stays 1200 — *silently*. sysusers fills absence; it does
  not reconcile drift.
- **Change** shell, home, GECOS, or primary group of an account that already
  exists (beyond what `m` adds as supplementary membership).
- **Delete** anything. Removing the file does not remove the account.
- **Manage human/login users.** It is explicitly for the **system range** only,
  and it bypasses NSS, so it is wrong for regular users (UID ≥ 1000) backed by
  passwords, real homes, or a directory service.

The consequence for rollout planning:

> sysusers is an excellent **provisioner** and a poor **enforcer**. Design so
> accounts are created *by* sysusers from the start. If you need to *guarantee*
> an existing account's UID matches the file even when it is already wrong, that
> remediation is still a job for Ansible or a script — sysusers will not fix it.

---

## 13. The companion you will always pair it with: tmpfiles.d

sysusers makes the **account**; it does not make the account's **directories**.
That is `systemd-tmpfiles`' job, and the two are designed to ship together:

```
# /usr/lib/sysusers.d/acme.conf
u  acme  -  "ACME collector"  /var/lib/acme  /usr/sbin/nologin

# /usr/lib/tmpfiles.d/acme.conf
d  /var/lib/acme   0750  acme  acme  -
d  /var/log/acme   0750  acme  acme  -
```

sysusers guarantees `acme` exists before tmpfiles chowns directories to it.
Together they replace the entire `useradd … && mkdir … && chown …` block of a
legacy provisioning script with two declarative files that live in the package
and self-heal on boot.

This is the heart of the broader pattern: the OS ships a complete *description*
of the state it needs (`sysusers.d` for accounts, `tmpfiles.d` for files and
directories), and systemd instantiates that state wherever the image lands.

---

## 14. A suggested adoption plan

A low-risk path to start using this in a real environment:

1. **Inventory.** Find your current system-account provisioning — `useradd`
   calls in Kickstart `%post`, RPM scriptlets, and Ansible `user:`/`group:`
   tasks for *service* (not human) accounts.
2. **Start with one site file.** Create
   `/etc/sysusers.d/site-accounts.conf` containing your standard service
   accounts. **Pin** the UIDs of any that touch NFS or shared storage;
   auto-allocate (`-`) the rest. Distribute it with your existing config
   management.
3. **Validate with `--dry-run`** in your pipeline before it reaches hosts.
4. **Adopt per-application pairs.** For each piece of in-house software you
   package, add a `sysusers.d` + `tmpfiles.d` pair to its RPM, and delete the
   corresponding scriptlet logic.
5. **Leave existing wrong accounts to remediation.** Remember §12 — for hosts
   that already have an account with the wrong UID, fix those with a one-time
   Ansible task; sysusers will not correct them.
6. **Converge freely.** Because it is idempotent, you can run `systemd-sysusers`
   on every config-management pass without side effects.

---

## 15. Quick reference

### Types

| Type | Purpose |
|---|---|
| `u` | Create system user + matching group |
| `u!` | Create + **fully lock** (systemd **v257+**, not on RHEL 8/9) |
| `g` | Create a group only |
| `m` | Add an existing user to a group (supplementary) |
| `r` | Reserve a UID/GID allocation range |

### ID field

| Value | Meaning |
|---|---|
| `-` | Auto-allocate (preferred for box-local accounts) |
| `999` | Pin UID |
| `999:998` | Pin UID:GID |
| `999:groupname` | Pin UID, use existing group as primary |
| `/path` | Inherit UID/GID from the path's owner |

### Directories (priority high → low)

```
/etc/sysusers.d/      ← your site policy
/run/sysusers.d/      ← runtime/volatile
/usr/lib/sysusers.d/  ← packages
```

### Commands

```
systemd-sysusers --dry-run            # preview
systemd-sysusers                      # apply all
systemd-sysusers FILE                 # apply one
systemd-sysusers --root=/mnt/img      # offline image
systemd-sysusers --cat-config         # show merged config
getent passwd NAME                    # verify
journalctl -u systemd-sysusers        # inspect boot-time run
```

### Golden rules

- Auto-allocate box-local accounts; **pin** anything that touches NFS/shared
  storage.
- System/service accounts only — never human or directory users.
- Additive only: it creates the missing, never modifies or deletes the existing.
- Pair every `u` with a `tmpfiles.d` entry if the account needs directories.
- `--dry-run` in CI; `/etc/sysusers.d/` for site policy; `/usr/lib/sysusers.d/`
  for packages.

---

*Verified against `sysusers.d(5)` (systemd). Behavior described applies to
RHEL 8 (systemd 239) and RHEL 9 (systemd 252) except where a later version is
explicitly noted.*
