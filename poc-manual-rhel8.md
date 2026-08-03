# OpenVox all-in-one POC — manual build (RHEL 8)

A step-by-step build of a single-host OpenVox proof of concept:
`openvox-server` + CA + `openvoxdb` + PostgreSQL + `openvox-gui`, all on one
RHEL 8 box. Each step explains *why*, not just *what*, so you can follow the
mechanism rather than paste blindly.

## What this POC proves — and what it doesn't

This validates the **software chain**: certificate signing, catalog
compilation, agents reporting into OpenVoxDB, and a dashboard rendering runs and
reports. It is a learning and demo environment.

It is **not** a scaled-down production topology. There is deliberately no
high availability, no separation of the CA onto its own host, and no
`soft_write_failure` safety net. Do not extrapolate sizing or availability
numbers from it. When you outgrow it, the production design is a separate
document.

## Host requirements

| | |
|---|---|
| OS | RHEL 8 (fresh) |
| Size | 4 vCPU / 8 GB RAM / 40 GB disk |
| Name | A real FQDN with a dot in it, e.g. `voxpoc.lab.example.com` |
| Access | root / sudo |

8 GB is the floor, not a suggestion. Three JVMs (server, db) plus PostgreSQL on
4 GB spends the whole POC fighting the OOM killer. On 8 GB the heap caps below
leave comfortable headroom.

## Before you start

Set these two variables once. Every command in this guide assumes they are
present in your shell.

```bash
export FQDN=voxpoc.lab.example.com
export PATH="/opt/puppetlabs/bin:/opt/puppetlabs/puppet/bin:$PATH"
```

Replace the FQDN with your host's actual fully-qualified name.

---

## Step 0 — Make the host resolve its own FQDN

The agent on this box connects to the server as `$FQDN`, and the CA issues a
certificate for that exact name. If the name does not resolve, you will hit TLS
errors later that look like CA problems but are really name-resolution problems.

```bash
getent hosts "$FQDN" || echo "127.0.1.1 $FQDN ${FQDN%%.*}" | sudo tee -a /etc/hosts
```

Use a real dotted FQDN. A bare hostname works right up until you add a second
node or put a proxy in front, and then it doesn't.

---

## Step 1 — Enable the OpenVox repository

The release RPM simply drops in the repository definition and its GPG signing
key.

```bash
sudo dnf install -y https://yum.voxpupuli.org/openvox8-release-el-8.noarch.rpm
```

For a real fleet you would mirror this internally so that hundreds of hosts do
not all pull from voxpupuli.org. For a one-box POC, straight upstream is fine.

---

## Step 2 — Install the packages

```bash
sudo dnf install -y openvox-server openvoxdb openvox-agent openvoxdb-termini
```

What each package is for:

- **openvox-server** — compiles catalogs and hosts the certificate authority.
- **openvoxdb** — stores facts, catalogs and reports.
- **openvox-agent** — converges this node; the host will manage itself.
- **openvoxdb-termini** — the glue that lets the *server* talk to the database.

Installing does not configure or start anything, and it does not wire the
components together. That is the next several steps.

---

## Step 3 — Cap the JVM heaps BEFORE first start

This is the step people skip and then wonder why an 8 GB box is crawling. The
server JVM, the database JVM, and PostgreSQL will each happily grab around 2 GB
by default and push the host into swap. Pin them before anything starts.

**Server** — edit `/etc/sysconfig/puppetserver` and set the `JAVA_ARGS` line to:

```
JAVA_ARGS="-Xms2g -Xmx2g -XX:ReservedCodeCacheSize=512m -Djruby.logger.class=com.puppetlabs.jruby_utils.jruby.Slf4jLogger"
```

`-Xms` equal to `-Xmx` means the heap does not resize under load. The reserved
code cache is where JRuby's compiled Ruby lives; 512m is ample for a POC.

**Database** — edit `/etc/sysconfig/puppetdb` and set:

```
JAVA_ARGS="-Xms1g -Xmx1g"
```

**JRuby pool** — drop it from the default to 2. This alone frees roughly a
gigabyte, and two compile workers are plenty for a POC:

```bash
sudo puppet config set --section master max_active_instances 2
```

If you are on 4 GB rather than 8, use `1g` for the server and `768m` for the
database, and expect slower compiles. On 8 GB the numbers above budget roughly
2 GB (server) + 1 GB (db) + ~1 GB (PostgreSQL) + ~0.25 GB (GUI), leaving
headroom.

---

## Step 4 — Set the certname and start the CA

```bash
sudo puppet config set --section main   certname "$FQDN"
sudo puppet config set --section main   server   "$FQDN"
sudo puppet config set --section master dns_alt_names "$FQDN,puppet,$(hostname -s)"
sudo systemctl enable --now puppetserver
```

Starting `puppetserver` for the first time bootstraps the CA and issues the
server's own certificate.

The `dns_alt_names` matter even on a single box. Baking `puppet` and the short
hostname into the certificate now means that if you later put a load balancer in
front, or split the CA onto its own host, agents validating against those names
will not need their certificates re-issued. It is a free bit of future-proofing
you cannot add retroactively without regenerating the cert.

First start takes 30–60 seconds while the JVM warms up and the CA initialises.
Watch it come up:

```bash
sudo systemctl status puppetserver
sudo ss -tlnp | grep 8140
```

---

## Step 5 — Wire the server to OpenVoxDB

Two things happen here: tell the server to *use* the database, and tell it
*where* the database is.

Turn on storeconfigs and PuppetDB-backed reports:

```bash
sudo puppet config set --section master storeconfigs true
sudo puppet config set --section master storeconfigs_backend puppetdb
sudo puppet config set --section master reports 'store,puppetdb'
```

Point the server at the database. Create `/etc/puppetlabs/puppet/puppetdb.conf`:

```ini
[main]
server_urls = https://voxpoc.lab.example.com:8081
soft_write_failure = false
```

> **Note the value of `soft_write_failure`.** Here it is `false`, which is the
> *opposite* of production. In production you set it `true` so that a database
> outage does not stop the fleet converging. In a POC you want the opposite:
> if the database is misconfigured, you want runs to fail loudly so you notice,
> rather than silently dropping reports.

Route facts through PuppetDB. Create `/etc/puppetlabs/puppet/routes.yaml`:

```yaml
---
master:
  facts:
    terminus: puppetdb
    cache: yaml
```

This is what makes the server read and write fact data via OpenVoxDB instead of
flat files on disk.

---

## Step 6 — Initialise OpenVoxDB and PostgreSQL

OpenVoxDB ships a helper that creates the database, the role, the required
extensions, and writes its own `[database]` configuration against a local
PostgreSQL:

```bash
sudo puppetdb setup
```

The command is still `puppetdb`, not `openvoxdb`. OpenVox keeps the original
service and CLI names for drop-in compatibility, which is also why upstream
Puppet documentation applies unchanged.

Tune retention down — a POC does not need two weeks of history and you are on a
smallish disk. Edit `/etc/puppetlabs/puppetdb/conf.d/database.ini` and add these
under the `[database]` section:

```ini
report-ttl = 3d
resource-events-ttl = 1d
node-purge-ttl = 7d
```

Then start it:

```bash
sudo systemctl enable --now puppetdb
sudo systemctl status puppetdb
```

> **If `puppetdb setup` complains about not finding a database**, PostgreSQL may
> need to be installed and initialised first:
>
> ```bash
> sudo dnf install -y postgresql-server
> sudo postgresql-setup --initdb
> sudo systemctl enable --now postgresql
> ```
>
> Then re-run `sudo puppetdb setup`. Whether this is needed depends on your
> exact package versions.

---

## Step 7 — Prove the loop

Run the agent against the local server. The first run generates a certificate
signing request; because the CA is on this same box and you have not configured
autosign, you sign it by hand — exactly once.

```bash
sudo puppet agent -t --server "$FQDN"     # generates the CSR, then exits
sudo puppetserver ca sign --certname "$FQDN"
sudo puppet agent -t --server "$FQDN"     # now completes a full run
```

That second run compiles a catalog, applies it, and ships facts and a report
into OpenVoxDB. That is the entire chain working end to end.

In production you would never hand-sign; you would use policy-based autosign
with a shared secret validated against the CSR. On one box, signing a single
certificate by hand is simpler and shows you the mechanism directly.

---

## Step 8 — Enable the agent service

So the host keeps managing itself on the normal interval:

```bash
sudo puppet resource service puppet ensure=running enable=true
```

---

## Verify the base stack

```bash
sudo puppetserver ca list --all                          # your cert, signed
curl -sk https://$FQDN:8081/status/v1/services | head    # database serving
sudo puppet agent -t                                     # a clean run
```

If all three are healthy, the base stack is complete and you are ready to add
the dashboard.

---

## Step 9 — Install the openvox-gui dashboard

`openvox-gui` (github.com/cvquesty/openvox-gui) is a community web interface —
**not** a Vox Pupuli project. It is Python/FastAPI + React, current stable is
the 3.10.x line, and it serves on **port 4567**.

It **must** run on the OpenVox Server host because it needs local access to the
CA, configuration files and services. On this all-in-one POC that is this same
box, which is exactly its supported layout. (This also means "dashboard on its
own VM" is not possible with this particular GUI — if you want that, Puppetboard
or OpenVox View are the alternatives.)

### 9a. Prerequisites

It needs Python 3.10+ and git:

```bash
sudo dnf install -y git python3 python3-pip curl
python3 --version        # confirm 3.10 or newer
```

### 9b. Clone a pinned release

```bash
sudo mkdir -p /opt/src
sudo git clone https://github.com/cvquesty/openvox-gui.git /opt/src/openvox-gui
cd /opt/src/openvox-gui
sudo git checkout v3.10.6      # check the releases page for a newer stable
```

### 9c. Run its interactive installer

```bash
sudo ./install.sh
```

The installer asks several questions. Sensible POC answers:

- **SSL** — reuse the OpenVox Server ("Puppet") certificates. One click, no
  separate cert to manage.
- **Agent-installer package mirror** — **skip** the initial sync. It downloads
  1–2 GB of agent packages and takes 15–45 minutes; you do not need it to see
  dashboards and reports.
- **Admin user** — create it when prompted.

### 9d. Log in

```bash
# Password was written here by the installer:
sudo cat /opt/openvox-gui/config/.credentials
```

Browse to `https://voxpoc.lab.example.com:4567`, log in as `admin`, and
**change the password immediately**.

### 9e. Optional — full metrics

Some Insights / Server-Health / DB-Health charts stay empty until you apply the
metrics configuration the project documents in `docs/METRICS.md` (`auth.conf` +
`metrics.conf` on the OpenVox Server). Basic dashboards, node lists, reports, CA
management and the PQL console all work without it, so this is optional for a
first look.

---

## Making the dashboard interesting: add a second node

A dashboard showing one node is not much of a demo. To add another:

1. On a second VM, install the release RPM (Step 1) and then just the agent:
   ```bash
   sudo dnf install -y openvox-agent
   ```
2. Point it at this server:
   ```bash
   sudo /opt/puppetlabs/bin/puppet config set --section main server voxpoc.lab.example.com
   sudo /opt/puppetlabs/bin/puppet agent -t        # generates its CSR
   ```
3. Back on the POC host, sign it — either on the CLI or through the GUI's
   **Infrastructure → Agent Install** page:
   ```bash
   sudo puppetserver ca sign --certname <second-node-fqdn>
   ```
4. Run the agent again on the second node; it will appear in the dashboard.

---

## RHEL 8 specifics to watch

**SELinux** is enforcing by default. The packages ship with the correct
contexts and it is usually fine, but if a service refuses to start or cannot
read a certificate, check for denials before assuming it is a config problem:

```bash
sudo ausearch -m avc -ts recent
```

**firewalld** — nothing needs opening for a single all-in-one box, because every
component talks over loopback. The moment you add a second agent node, open the
catalog/CA port on this host:

```bash
sudo firewall-cmd --add-port=8140/tcp --permanent
sudo firewall-cmd --reload
```

Port 8081 (OpenVoxDB) only needs opening if something queries the database
remotely, which a basic POC does not.

---

## How the pieces fit together

```
        +-------------------- one RHEL 8 host --------------------+
        |                                                         |
  agent | puppet agent -t                                         |
  --->  |    | catalog request (8140, mutual TLS)                 |
        |    v                                                    |
        |  openvox-server ---- CA (signs certs, 8140)             |
        |    |                                                    |
        |    | facts / catalog / report (8081)                   |
        |    v                                                    |
        |  openvoxdb  <---->  PostgreSQL (localhost 5432)         |
        |    ^                                                    |
        |    | reads reports, facts, certs                       |
        |  openvox-gui  (web UI on 4567)                          |
        |                                                         |
        +---------------------------------------------------------+
```

- **openvox-server** compiles catalogs and, on this host only, runs the CA.
- **openvoxdb + PostgreSQL** store facts, catalogs and reports.
- **openvox-gui** reads OpenVoxDB and the local CA to show nodes, reports,
  certificates, PQL results and metrics.

---

## How this POC differs from production (all deliberate)

| POC | Production |
|---|---|
| CA on the same host as everything | CA is a single-writer on its own name, backed up and restore-tested |
| `soft_write_failure = false` | `true`, so a DB outage does not stop convergence |
| Sign the first cert by hand | Policy-based autosign with a rotating shared secret |
| One compiler | Three compilers behind an HAProxy VIP |
| PostgreSQL local, near-default | Sized, on NVMe, with tuned retention |
| Retention 3 days | 7–14 days |
| Everything one repo of config | Control repo + separate app-data repo, GitLab pipelines |

---

## Teardown

It is a throwaway VM, so the cleanest teardown is to delete it. To reclaim the
packages in place instead:

```bash
sudo systemctl stop openvox-gui puppetserver puppetdb || true
sudo dnf remove -y 'openvox*'
sudo rm -rf /etc/puppetlabs /opt/puppetlabs /opt/openvox-gui /opt/src/openvox-gui
```

---

## Quick command reference

```bash
# Service state
sudo systemctl status puppetserver puppetdb openvox-gui

# Certificates
sudo puppetserver ca list --all                 # all known certs
sudo puppetserver ca sign --certname NAME       # sign a pending CSR

# Run the agent on demand
sudo puppet agent -t

# Is the database healthy?
curl -sk https://$FQDN:8081/status/v1/services | head

# Logs
sudo journalctl -u puppetserver -n 100
sudo journalctl -u puppetdb -n 100
sudo journalctl -u openvox-gui -f

# Memory sanity check (watch for swap)
free -m
```
