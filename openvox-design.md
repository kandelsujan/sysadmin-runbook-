# OpenVox configuration management platform

**Design and build document**

| | |
|---|---|
| Scope | ~1,600 Linux hosts, Ubuntu and RHEL |
| Platform | OpenVox 8 (community fork of Puppet) |
| Deployment | Greenfield |
| Status | Design agreed; not yet built |
| Last updated | 2026-07-23 |

---

## 1. Purpose and scope

This document describes a redundant OpenVox configuration management platform for approximately 1,600 Linux hosts running a mixture of Ubuntu and RHEL, together with the GitLab repository structure and CI pipelines that deliver code and data to it.

It covers:

- Server-side infrastructure: compilers, certificate authority, OpenVoxDB, PostgreSQL, load balancers, dashboards
- Certificate architecture and node classification
- Repository layout for Puppet code and Hiera data, and the access model between them
- GitLab configuration, pipelines, and the code deployment path
- Operational runbooks, backup, and failure modes

It does not cover: host provisioning (assumed to exist), the contents of application-specific profiles, or network/firewall implementation beyond the ports the platform requires.

### 1.1 Terminology

OpenVox is the community-maintained fork of Puppet, produced by Vox Pupuli after Perforce stopped publishing open-source Puppet releases. It is functionally Puppet: modules from the Forge work, the DSL is unchanged, and upstream Puppet documentation applies. The renamed components are:

| Puppet | OpenVox | Notes |
|---|---|---|
| puppet-agent | openvox-agent | Binaries still install to `/opt/puppetlabs` |
| puppetserver | openvox-server | Service is still named `puppetserver` |
| puppetdb | openvoxdb | |
| puppetdb-termini | openvoxdb-termini | |
| bolt | openbolt | |
| facter | openfact | |

Throughout this document "compiler" means a host running `openvox-server` that compiles catalogs, and "agent" means a managed node running `openvox-agent`.

---

## 2. Design principles

Five decisions shape everything else. Each is recorded here with its rationale so that future changes are made deliberately rather than by accident.

### 2.1 Redundancy buys availability, not durability — except for the CA

Rank what is actually lost in each failure:

| Component | What is lost | Recovery |
|---|---|---|
| CA private keys | Irreplaceable. Every node must be re-certified by hand. | Backup and restore only |
| Git repositories | Nothing. GitLab is separately backed up. | Someone else's problem |
| Compiler | Configuration changes stop reaching the fleet | Rebuild from Puppet code |
| OpenVoxDB / PostgreSQL | Report history only. Facts, catalogs and node inventory fully regenerate within one run interval. | Rebuild, wait one run interval |

The consequence is that a PostgreSQL cluster protects the one thing in the estate that rebuilds itself, while the CA — which cannot be rebuilt — needs backups, not clustering. The redundancy budget goes to compilers and to CA backups.

### 2.2 Three compilers, not two larger ones

The binding constraint is the degraded case: whatever survives a compiler failure must carry the whole fleet at the target run interval. Two compilers means each must be sized to stand alone. Three smaller ones deliver the same aggregate compute with a better failure profile, are faster to rebuild, and allow patching during business hours.

With a load balancer in place, adding a compiler is one `server` line and a certificate. This was the deciding argument for keeping HAProxy rather than using agent-side `server_list` failover, which would require re-sharding agents on every capacity change.

### 2.3 Classification comes from the certificate, never from hostname

Nodes are classified by a `pp_role` extension baked into the certificate signing request at provisioning time. The CA signs it, so nothing running on the node can alter it. It drives both `site.pp` and the Hiera hierarchy from one authoritative source, and it composes with the autosign policy.

Hostname-regex classification is prohibited. It is invisible to `octocatalog-diff`, breaks silently on renames, and cannot be audited.

### 2.4 Data lives in Hiera; manifests contain no site values

No profile hardcodes a URL, a path, a package name, a timeout, or an operating system name. Profiles declare parameters and iterate over data structures. Adding Ubuntu 26.04 or EL10 support is a new file under `data/os/`; it is never a manifest change.

Parameter defaults in class signatures are permitted as the API contract, but every one is also set explicitly in `data/common.yaml` so the data path stays authoritative.

### 2.5 Code and data live in separate repositories with asymmetric access

Application teams need to change Hiera data without gaining write access to the Puppet code that governs the estate. They have **read** access to the control repository — so they can understand what a profile does — and **write** access only to the application data repository.

Read access is not write access. The security boundary is `app_overridable.yaml` in the control repo, which lists the key patterns application teams may set, enforced by the data repository's pipeline.

---

## 3. Architecture

### 3.1 Component inventory

| Role | Hostname | Count | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|---|---|
| Compiler + CA | `vox1` | 1 | 8 | 16 GB | 100 GB | CA service enabled |
| Compiler | `vox2`, `vox3` | 2 | 8 | 16 GB | 100 GB | CA service disabled |
| Test compiler | `voxtest1` | 1 | 4 | 8 GB | 100 GB | Not in the LB pool; serves feature branches |
| Data node | `voxdata1` | 1 | 8 | 32 GB | 1 TB NVMe | OpenVoxDB + PostgreSQL + dashboard |
| Load balancer | `lb1`, `lb2` | 2 | 2 | 4 GB | 40 GB | HAProxy + keepalived |

Seven VMs total.

### 3.2 Names

| Name | Type | Points at | Purpose |
|---|---|---|---|
| `puppet.example.com` | A | `10.0.0.10` (VIP) | Agent-facing catalog service |
| `puppetca.example.com` | CNAME | `vox1.example.com` | Certificate authority |
| `voxdata1.example.com` | A | data node | OpenVoxDB and dashboard |

`puppetca` is deliberately a CNAME. Failing the CA over to a rebuilt host is then a DNS change and nothing else.

### 3.3 Capacity model

At a 30-minute run interval, 1,600 nodes generate approximately 0.9 catalog compiles per second. At 5–10 seconds per compile that is roughly 7 JRuby instances busy at steady state.

| | Total JRubies | Concurrent capacity |
|---|---|---|
| All three compilers healthy | 18 | ~2.5× steady state |
| One compiler lost | 12 | ~1.7× steady state |
| Two compilers lost | 6 | ~0.85× steady state — degraded, run interval must be relaxed |

`max-active-instances` is set to 6 per compiler with an 8 GB fixed heap and 1 GB reserved code cache. JRuby needs roughly 128 MB of code cache per instance plus 1–2 GB of heap each; the JVM's max heap is what actually limits how high this setting can go.

Agents are configured with `splay = true` and `splaylimit = 30m`. Without splay, a synchronised wave arrives every half hour, saturating the JRuby pool while it sits idle in between.

### 3.4 Network and ports

| Source | Destination | Port | Protocol | Purpose |
|---|---|---|---|---|
| Agents (all 1,600) | `puppet.example.com` VIP | 8140 | TCP/TLS | Catalog requests |
| Agents (all 1,600) | `puppetca.example.com` | 8140 | TCP/TLS | Certificate signing, CRL |
| Load balancers | Compilers | 8140 | TCP/TLS | Backend, passthrough |
| Compilers | `voxdata1` | 8081 | HTTPS | OpenVoxDB commands and queries |
| Compilers | GitLab | 22 or 443 | SSH/HTTPS | r10k code deploy |
| GitLab runners | Compilers | 22 | SSH | Deploy trigger (forced command) |
| Dashboard | OpenVoxDB | 8081 | HTTPS | Localhost on `voxdata1` |
| OpenVoxDB | PostgreSQL | 5432 | TCP | Localhost on `voxdata1` |
| Operators | Dashboard, Grafana | 443 | HTTPS | |
| `lb1` ↔ `lb2` | — | VRRP (112) | IP | keepalived |

### 3.5 Load balancer configuration

HAProxy operates in **TCP passthrough mode**. This is not negotiable: OpenVox authorisation is entirely certificate-based, and terminating TLS at the load balancer strips the client certificate, breaking authorisation on every request.

```
listen openvox
    bind 10.0.0.10:8140
    mode tcp
    balance leastconn
    timeout client 30m
    timeout server 30m
    option tcplog
    option httpchk GET /status/v1/simple
    http-check expect string running
    server vox1 10.0.1.11:8140 check check-ssl verify none inter 10s fall 3 rise 2
    server vox2 10.0.1.12:8140 check check-ssl verify none inter 10s fall 3 rise 2
    server vox3 10.0.1.13:8140 check check-ssl verify none inter 10s fall 3 rise 2
```

Notes:

- `leastconn` rather than round-robin. Agent connections are long-lived, so connection count is a better proxy for load than request count.
- Timeouts must comfortably exceed the slowest catalog compile. A connection truncated mid-compile produces confusing agent-side errors that look like network faults.
- The health check uses `/status/v1/simple`, which the default `auth.conf` permits unauthenticated. `check-ssl verify none` is required because the check speaks TLS but has no client certificate.
- **The CA is not behind this VIP.** Only one host can sign certificates; balancing CA traffic across three compilers produces intermittent, hard-to-diagnose failures.

One operational side effect: in passthrough mode the compiler's access logs record the load balancer's address, not the agent's. Authorisation is unaffected because it is certificate-based, but log analysis must key on certname rather than source IP.

### 3.6 The data node

`voxdata1` runs OpenVoxDB, its PostgreSQL instance, and the dashboard on a single host with no redundancy. This is deliberate, per §2.1.

The change that makes it safe is `soft_write_failure` on the compilers:

```ini
# /etc/puppetlabs/puppet/puppetdb.conf on each compiler
[main]
server_urls = https://voxdata1.example.com:8081
soft_write_failure = true
```

With this set, an OpenVoxDB outage means agent runs still complete and still enforce configuration — facts, catalogs and reports are simply dropped for the duration. Without it, runs hard-fail and the entire fleet stops converging because a reporting database is down. That is the wrong failure mode.

The caveat: `soft_write_failure` covers writes, not reads. Exported resources and `puppetdb_query()` calls in manifests still fail during an outage. **Do not build core infrastructure on exported resources.** Treat OpenVoxDB as observability, not as a dependency.

Compilers also lower the PuppetDB HTTP timeout from its 120-second default:

```
# puppetserver.conf
http-client: { connect-timeout-milliseconds: 10000 }
```

A stalled connection to a dead OpenVoxDB otherwise occupies a JRuby instance for two full minutes.

---

## 4. Software versions and repositories

### 4.1 Version selection

Build on **OpenVox 8**. The current stable line is `openvox-server` / `openvoxdb` 8.14.1.

- 8.14.1 upgraded Jetty from 10 to 12. Jetty handles all API traffic for both Server and DB, so read the release notes before pinning.
- OpenVox 9.0.0~beta1 shipped in July 2026 (Ruby 4.0, Java 25, JRuby 10, PostgreSQL 17/18). Not suitable for a production fleet of this size yet.
- OpenVox 8 enters maintenance mode once 9 branches. Plan a 9.x upgrade for the following year.

### 4.2 Package repositories

Release packages configure the repository and its signing keys:

| Platform | Release package |
|---|---|
| Ubuntu 22.04 | `https://apt.voxpupuli.org/openvox8-release-ubuntu22.04.deb` |
| Ubuntu 24.04 | `https://apt.voxpupuli.org/openvox8-release-ubuntu24.04.deb` |
| EL 8 | `https://yum.voxpupuli.org/openvox8-release-el-8.noarch.rpm` |
| EL 9 | `https://yum.voxpupuli.org/openvox8-release-el-9.noarch.rpm` |

**Mirror both internally.** At 1,600 hosts you do not want every agent reaching out to voxpupuli.org for every package operation. Use aptly, Pulp, or Katello. The repository definitions in Hiera (`data/os/*.yaml`) point at the internal mirrors, not at the upstream.

Only `vox1` needs the initial upstream access, during bootstrap.

---

## 5. Certificate architecture

### 5.1 Single writer

Exactly one host signs certificates. On `vox2`, `vox3` and `voxtest1` the CA service is disabled by editing `/etc/puppetlabs/puppetserver/services.d/ca.cfg` to use `certificate-authority-disabled-service` instead of `certificate-authority-service`. In the control repo this is expressed as `profile::openvox::compiler::ca: false` (the default), overridden to `true` only in `data/role/openvox_ca.yaml`.

Agents are pointed at the CA separately from the catalog service:

```ini
[main]
server      = puppet.example.com
ca_server   = puppetca.example.com
runinterval = 30m
splay       = true
splaylimit  = 30m
```

A CA outage does not stop catalog compilation. It blocks new certificate issuance and CRL refresh only. A cold standby restored from backup, with a DNS CNAME change, is an appropriate recovery posture.

### 5.2 Subject alternative names

Agents validate the certificate presented by whichever compiler the load balancer selected, against the name they connected to. Every compiler certificate must therefore carry the VIP name:

```bash
puppetserver ca generate \
  --certname vox2.example.com \
  --subject-alt-names puppet.example.com,vox2.example.com
```

`vox1` additionally carries `puppetca.example.com`.

Getting this wrong produces certificate verification failures that present as a CA problem but are not one. Verify with:

```bash
openssl x509 -in /etc/puppetlabs/puppet/ssl/certs/vox2.example.com.pem -noout -text | grep -A1 'Subject Alternative Name'
```

### 5.3 Autosigning

`autosign = true` is prohibited. On a fleet this size it allows anything that can reach port 8140 to obtain a signed certificate for any certname it chooses, including one belonging to an existing host.

Policy-based autosigning is used instead. At provisioning time each host writes `/etc/puppetlabs/puppet/csr_attributes.yaml` **before** its first agent run:

```yaml
---
custom_attributes:
  challengePassword: '<shared secret from the provisioning system>'
extension_requests:
  pp_role:       app_billing
  pp_datacenter: den1
```

`/etc/puppetlabs/puppet/autosign.rb` on the CA validates:

1. The `challengePassword` matches the current shared secret
2. The requested `pp_role` appears in an allowlist of known roles
3. No certificate already exists for that certname

`custom_attributes` are used only during signing and are discarded. `extension_requests` are embedded in the signed certificate permanently — which is what makes `pp_role` trustworthy.

Rotate the shared secret on a schedule and after any provisioning-system compromise.

---

## 6. Node classification

### 6.1 Mechanism

`manifests/site.pp` reads the signed extension and includes the corresponding role class:

```puppet
node default {
  $pp_role = $trusted['extensions']['pp_role']

  unless $pp_role =~ String[1] {
    fail("${trusted['certname']} has no pp_role extension in its certificate.")
  }

  unless $pp_role =~ /\A[a-z][a-z0-9_]*\z/ {
    fail("pp_role '${pp_role}' is not a valid class name component.")
  }

  include "role::${pp_role}"
}
```

Because the value comes from `$trusted`, it cannot be forged by anything running on the node — unlike a custom fact, which is simply a file on the node's own disk.

The class raises a hard failure for any node lacking a role. This is intentional: on day one, when the pattern is still being learned, a loud failure is preferable to a node silently receiving an empty catalog.

### 6.2 Roles and profiles

- A **role** describes what a machine is for the business. It contains only `include` statements and inherits `role::base`. One role per `pp_role` value.
- A **profile** describes how one technology is configured at this site. It takes parameters and declares resources. It contains no site-specific values.
- Everything reusable across sites lives in its own module repository and arrives via the `Puppetfile`.

```puppet
class role::app_billing inherits role::base {
  include profile::app::billing
  include profile::monitoring::app_billing
}
```

Adding a node type is: a `pp_role` value, a file in `data/role/`, and a class in `site-modules/role/manifests/`.

---

## 7. Repository architecture

### 7.1 Projects

All repositories live under a single GitLab group so that access is granted by group membership rather than repository by repository.

```
gitlab.example.com/puppet/
├── control-repo          Puppet code + platform Hiera data
├── puppet-appdata        Application team Hiera data
└── modules/
    ├── puppet-acme_app
    └── puppet-acme_monitoring
```

| Repository | Contains | Platform team | App teams |
|---|---|---|---|
| `control-repo` | Manifests, profiles, roles, `Puppetfile`, `common.yaml`, `os/`, `location/`, `role/openvox_*.yaml`, `nodes/` | Write | **Read** |
| `puppet-appdata` | `role/app_*.yaml`, `nodes/` | Write | Write |
| `modules/*` | Reusable modules, one per repository | Write | Read |

### 7.2 Why the split is on ownership, not on code-versus-data

A naive code/data split puts everything under `data/` into the second repository. That would give application teams write access to `common.yaml`, `os/*.yaml` and the load balancer configuration — estate-wide values where a typo reaches all 1,600 nodes on the next run. That is a larger blast radius than the problem being solved.

The split is therefore on **ownership**. Platform data is platform's and stays with platform's code. Only genuinely application-owned data moves out.

### 7.3 Why application teams get read access to the code

Read access was granted deliberately, for two reasons:

1. **Catalog diff becomes possible in the data repository's pipeline.** A merge request that changes `app_billing.yaml` can show its author the resources that will actually change on `billing-app-01`. Without read access this requires special-cased tokens and artifact plumbing; with it, the pipeline simply clones the control repo.
2. **People who can read `profile::app` stop working around behaviour they do not understand.** It measurably reduces "why did Puppet overwrite my config file" tickets.

What read access does **not** protect against, and should not be relied upon to:

- Anyone with root on a node can read that node's full catalog at `/opt/puppetlabs/puppet/cache/client_data/catalog/*.json`, including file contents, sudo rules and firewall entries. An application team with root on its own servers can already see everything applied to those servers. What the repository boundary protects is the estate-wide view — compiler configuration, CA setup, security baselines, and anything applied to hosts they do not own.

**Before granting read access**, audit the control repository's full git history for plaintext secrets. Read access includes history, and the common pattern is a password committed in cleartext early and later migrated to eyaml — the migration does not remove it from old commits.

```bash
gitleaks detect --source . --log-opts="--all"
```

Rotate anything found rather than rewriting history on a repository already in use.

### 7.4 Control repository layout

```
control-repo/
├── .gitlab-ci.yml
├── .gitignore                  modules/ is never committed
├── .puppet-lint.rc
├── CODEOWNERS
├── Gemfile
├── Puppetfile                  every entry pinned
├── README.md
├── app_overridable.yaml        the security boundary of the split
├── environment.conf            modulepath + environment_timeout
├── hiera.yaml                  the hierarchy
├── manifests/
│   └── site.pp                 classification only
├── data/
│   ├── common.yaml             estate-wide defaults + lookup_options
│   ├── os/
│   │   ├── Ubuntu-22.04.yaml   release-specific: repo URLs, release strings
│   │   ├── Ubuntu-24.04.yaml
│   │   ├── RedHat-8.yaml
│   │   ├── RedHat-9.yaml
│   │   ├── Debian.yaml         family-wide values only
│   │   └── RedHat.yaml
│   ├── location/
│   │   └── den1.yaml
│   ├── role/
│   │   └── openvox_*.yaml      platform roles only
│   └── nodes/
│       └── <certname>.yaml     platform emergency overrides
├── site-modules/               profile and role ONLY
│   ├── profile/manifests/
│   │   ├── base.pp
│   │   ├── base/{agent,repos,time}.pp
│   │   └── openvox/{ca,compiler,dashboard,db,loadbalancer,r10k}.pp
│   └── role/manifests/
│       ├── base.pp
│       └── openvox_{ca,compiler,db,lb}.pp
├── scripts/
│   ├── r10k-deploy.sh              forced-command deploy target
│   ├── generate-param-reference.rb parameter contract generator
│   ├── check-hiera-keys.rb         orphan key detection
│   └── check-puppetfile-pins.rb    unpinned module detection
└── modules/                    r10k-managed, gitignored
```

`site-modules/` contains `profile` and `role` and nothing else. Anything that could conceivably be reused at another site belongs in its own repository.

### 7.5 Application data repository layout

```
puppet-appdata/
├── .gitlab-ci.yml
├── README.md
├── diff_nodes.txt              representative certnames for catalog diff
├── data/
│   ├── role/
│   │   └── app_*.yaml
│   └── nodes/
│       └── <certname>.yaml
└── scripts/
    ├── validate-app-data.rb    key existence, permission, and type checks
    └── params                  local parameter discovery
```

This repository is deployed onto the compilers as a module named `appdata` via the control repository's `Puppetfile`:

```ruby
mod 'appdata',
  git:            'git@gitlab.example.com:puppet/puppet-appdata.git',
  branch:         :control_branch,
  default_branch: 'production'
```

`:control_branch` makes r10k check out the branch matching whichever control repo branch it is deploying, falling back to `default_branch` when no such branch exists. Production code therefore always pairs with production data, and a feature branch picks up matching data if the team created one. A team only needs a branch in the data repository if it is actually changing data.

---

## 8. Hiera hierarchy

`hiera.yaml` in the control repository, highest precedence first:

| # | Level | Path | Owner |
|---|---|---|---|
| 1 | Node secrets | `nodes/%{trusted.certname}.eyaml` | Platform |
| 2 | Node data | `nodes/%{trusted.certname}.yaml` | Platform |
| 3 | App role secrets | `modules/appdata/data/role/%{trusted.extensions.pp_role}.eyaml` | App teams |
| 4 | App role data | `modules/appdata/data/role/%{trusted.extensions.pp_role}.yaml` | App teams |
| 5 | Platform role secrets | `role/%{trusted.extensions.pp_role}.eyaml` | Platform |
| 6 | Platform role data | `role/%{trusted.extensions.pp_role}.yaml` | Platform |
| 7 | Location | `location/%{trusted.extensions.pp_datacenter}.yaml` | Platform |
| 8 | OS version | `os/%{facts.os.name}-%{facts.os.release.major}.yaml` | Platform |
| 9 | OS family | `os/%{facts.os.family}.yaml` | Platform |
| 10 | Common secrets | `common.eyaml` | Platform |
| 11 | Common | `common.yaml` | Platform |

Design notes on the ordering:

- **Node data sits above app data.** Platform retains an emergency override on any host, even for values an application team owns.
- **App data sits above platform role data.** Teams can override what platform has chosen to make overridable. Which keys those are is enforced by `app_overridable.yaml`, not by the hierarchy.
- **OS version sits above OS family.** Repository URLs, release strings and package names differ per release, so they belong at the version level. Family files hold only what is true across every release of that family. Supporting a new OS release is a new file here.
- **`pp_datacenter`, like `pp_role`, comes from the certificate**, so location cannot be spoofed by editing a fact on the node.

`lookup_options` in `common.yaml` controls merge behaviour and is platform-controlled. Without deep merge, one repository definition at role level silently discards every repository defined at OS level:

```yaml
lookup_options:
  profile::base::repos::apt_sources:
    merge: deep
  profile::base::repos::yum_repos:
    merge: deep
  profile::openvox::loadbalancer::compilers:
    merge: hash
```

Application teams cannot set `lookup_options`; the validation script rejects it explicitly.

---

## 9. Code and data separation

### 9.1 The rule

Manifests contain logic. Data contains values. A profile that knows what Ubuntu is has a defect.

**Before** — OS knowledge embedded in the manifest:

```puppet
class profile::base::repos {
  case $facts['os']['family'] {
    'Debian': { apt::source { 'openvox8': location => 'https://mirror...' } }
    'RedHat': { yumrepo { 'openvox8': baseurl => "https://mirror.../\$basearch" } }
  }
}
```

**After** — the manifest iterates, the data decides:

```puppet
class profile::base::repos (
  Hash[String[1], Hash] $apt_sources = {},
  Hash[String[1], Hash] $yum_repos   = {},
) {
  unless $apt_sources.empty {
    include apt
    $apt_sources.each |$title, $params| { apt::source { $title: * => $params } }
  }
  $yum_repos.each |$title, $params| { yumrepo { $title: * => $params } }
}
```

```yaml
# data/os/RedHat-9.yaml
profile::base::repos::yum_repos:
  openvox8-release:
    descr:    'OpenVox 8 EL9'
    baseurl:  'https://mirror.example.com/yum/openvox8/el/9/$basearch'
    enabled:  1
    gpgcheck: 1
    gpgkey:   'https://mirror.example.com/yum/RPM-GPG-KEY-voxpupuli'
```

Incidental benefit: `$basearch` is a literal in YAML, so the Puppet-side escaping disappears.

### 9.2 What is permitted in a manifest

| Permitted | Not permitted |
|---|---|
| Parameter defaults as the class API contract | Site values with no Hiera entry |
| Conditionals on parameter values | Conditionals on `$facts['os']['family']` for site data |
| Iteration over parameter hashes | Hardcoded URLs, paths, hostnames, ports |
| Type constraints on parameters | Magic numbers |

Every default in a class signature is also set explicitly in `data/common.yaml`, so the data path remains authoritative and the default is only a safety net.

### 9.3 The permission boundary

`app_overridable.yaml` in the control repository lists which key patterns the application data repository may set:

```yaml
allow:
  - '^profile::app::'
  - '^profile::monitoring::app_'
  - '^acme_app::'

deny:
  - '^profile::app::firewall::'
  - '^profile::app::sudo'
```

Explicit denies win over allows. Without this list, a team that owns `data/role/app_billing.yaml` could also set `profile::base::agent::runinterval` or `profile::openvox::compiler::jruby_instances` and affect the whole estate. Opening up a new parameter is a merge request in the control repository, reviewed by platform.

Because application teams can read the code, when platform declines to open a parameter up they can see why. That is worth more than the argument avoided by keeping it opaque.

---

## 10. GitLab configuration

### 10.1 Permissions

Grant access at the **group** level, not per repository. Adding a team then becomes a group membership change rather than a set of repository grants that someone will forget to revoke.

| Group / project | Principal | Level |
|---|---|---|
| `puppet/` (group) | Platform Engineering | Maintainer |
| `puppet/` (group) | Application teams | Reporter (read) |
| `puppet/puppet-appdata` | Application teams | Developer (write) |

Reporter on the group gives read across `control-repo` and `modules/*`; Developer on the single data project layers write on top of it.

### 10.2 Protected branches

Both repositories:

| Branch | Allowed to merge | Allowed to push | Force push |
|---|---|---|---|
| `production` | Maintainers | No one | Disabled |
| everything else | Developers | Developers | Allowed |

Enable **"Require approval from Code Owners"** on `production` in the control repository, backed by `CODEOWNERS`. Note this controls approval, not read access — read access is granted at the group level as above.

### 10.3 Branch naming

Branch name equals Puppet environment name, and Puppet environment names must match `[a-z0-9_]+`.

`feature/PUP-123` is **not** a legal environment name. r10k's default behaviour is to skip such branches silently, which produces "I pushed and nothing happened" tickets. The r10k configuration sets `invalid_branches: error` so it fails loudly instead.

Convention: `pup_123_add_nginx`.

### 10.4 CI variables

| Variable | Repository | Type | Notes |
|---|---|---|---|
| `R10K_DEPLOY_KEY` | control-repo | File, masked, **protected** | Private half of the SSH key for `puppet-deploy@` on the compilers |
| `SSH_KNOWN_HOSTS` | control-repo | File | Host keys for all four compilers |
| `EYAML_PUBLIC_KEY` | both | File | Encryption only; the private key is never in GitLab |

**Protected** means the variable is only exposed to jobs on protected branches. Without it, a merge request from a fork can exfiltrate the deploy key.

The eyaml **private** key exists only on the compilers, distributed by hand or from a secret store. CI can encrypt; CI cannot decrypt.

### 10.5 Job token allowlist

The application data pipeline clones the control repository using `CI_JOB_TOKEN`. This requires the control repository to allowlist the data repository:

> control-repo → Settings → CI/CD → Job token permissions → Add `puppet/puppet-appdata`

Without it the clone fails with a 404 that looks like a bad URL rather than a permissions problem. The same applies to the data repository's `trigger` job in the other direction.

---

## 11. Pipelines

### 11.1 Control repository

| Stage | Job | Purpose | Blocking |
|---|---|---|---|
| validate | `puppet:syntax` | `puppet parser validate`, `puppet-lint` | Yes |
| validate | `data:syntax` | `yamllint`, orphan Hiera key detection | Yes |
| validate | `puppetfile` | `r10k puppetfile check`, unpinned-module detection | Yes |
| validate | `reference` | Confirms `app_overridable.yaml` resolves against real parameters | Yes |
| unit | `rspec` | `rspec-puppet` compiles every role against representative facts | Yes |
| diff | `catalog:diff` | `octocatalog-diff` on merge requests | No (artifact) |
| deploy | `deploy:branch` | Manual deploy of a feature branch to `voxtest1` | No |
| deploy | `deploy:production` | Parallel deploy to all three compilers | Yes |

**Orphan key detection** (`check-hiera-keys.rb`) is more valuable than it sounds. Hiera silently ignores keys that nothing looks up, so a typo like `runintervall` sits in the data looking authoritative while doing nothing at all. The script extracts every class parameter from `site-modules/` and fails the pipeline on any fully-qualified key in `data/` that does not match one.

**Unpinned module detection** (`check-puppetfile-pins.rb`) fails the build on any `Puppetfile` entry without a version, tag or ref. An unpinned module means r10k can resolve different code on different compilers for the same environment, producing drift that is genuinely hard to reproduce.

**Catalog diff** is the highest-value gate. Lint proves the code parses; `octocatalog-diff` shows the reviewer which resources change on which real nodes. Keep it `allow_failure: true` until it is stable — it needs facts present in OpenVoxDB and will be flaky at first. Treat the artifact as review material.

### 11.2 Deploy job design

```yaml
deploy:production:
  stage: deploy
  resource_group: production
  environment:
    name: production
  rules:
    - if: $CI_COMMIT_BRANCH == 'production'
  parallel:
    matrix:
      - COMPILER: [vox1.example.com, vox2.example.com, vox3.example.com]
  script:
    - ssh puppet-deploy@"$COMPILER" "$CI_ENVIRONMENT_NAME"
```

- `resource_group: production` serialises deploys so two merges cannot race.
- `parallel:matrix` hits all three compilers. A failure on any one fails the job, so a compiler that is out of sync is discovered immediately rather than days later.

### 11.3 Feature branch environments

Feature branches deploy **only** to `voxtest1`, which is not in the HAProxy pool. With `environment_timeout = unlimited`, every environment on a compiler holds cached code in JRuby heap indefinitely. Twenty open merge requests would be twenty environments' worth of memory and disk across all three production compilers.

The `deploy:branch` job is manual, and its paired `undeploy:branch` job runs `on_stop` when the merge request closes, purging the environment directory.

### 11.4 Application data repository

| Stage | Job | Purpose |
|---|---|---|
| validate | `yaml` | `yamllint` |
| validate | `keys` | Clone control repo, generate parameter reference, validate every key |
| diff | `catalog:diff` | Assemble two environments, diff catalogs on merge requests |
| deploy | `deploy:production` | Trigger a control repo deploy |

`validate-app-data.rb` catches three failure modes that are invisible to a contributor reading only YAML:

1. **A key that does not exist.** Hiera ignores it silently, forever. The script suggests near-matches on the final path component.
2. **A key that exists but is platform-controlled.** Setting `profile::base::agent::runinterval` from an application role file would change behaviour on every node carrying that role.
3. **A value of the wrong shape.** Coarse type checking only — the compiler enforces the full type, but obvious mismatches are caught before they reach a node.

The catalog diff job assembles two complete environments — production data versus the branch's data, with the module tree hardlinked between them — and runs `octocatalog-diff --bootstrapped-from-dir / --bootstrapped-to-dir`.

> **Expect to tune this job.** The mechanism is correct but the r10k module install is slow; cache `modules/` between pipelines or it will add minutes to every merge request. Keep `allow_failure: true` until it is reliable.

### 11.5 Parameter discovery

Application teams can read the code, which tells them what parameters exist. It does not tell them which they are permitted to set. `scripts/generate-param-reference.rb` in the control repository emits `param-reference.json` — every parameter with its type, default, whether it is required, and whether it is app-overridable — and `scripts/params` in the data repository queries it:

```
./scripts/params --overridable
./scripts/params --search database
```

Platform-controlled parameters appear marked with `*`, so teams can see what exists without being able to set it.

---

## 12. Code deployment mechanics

### 12.1 Path from merge to node

```
merge to production
  → control repo pipeline: validate → unit → deploy
  → ssh puppet-deploy@voxN  (forced command)
  → r10k deploy environment production --puppetfile
      ├── control repo → /etc/puppetlabs/code/environments/production/
      └── appdata repo → .../production/modules/appdata/
  → DELETE /puppet-admin-api/v1/environment-cache
  → next agent run picks up new catalog (within 30 minutes)
```

### 12.2 The environment cache flush

`environment.conf` sets `environment_timeout = unlimited`. At 1,600 nodes the default of re-reading environment metadata on every request is a real cost, but it means **the server keeps serving the old code until the cache is explicitly dropped**.

Skipping the flush is the classic "I deployed but nothing changed" incident. `scripts/r10k-deploy.sh` performs it as the final step:

```bash
curl --fail --silent --show-error \
  --cert   "/etc/puppetlabs/puppet/ssl/certs/$(hostname -f).pem" \
  --key    "/etc/puppetlabs/puppet/ssl/private_keys/$(hostname -f).pem" \
  --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
  -X DELETE "https://$(hostname -f):8140/puppet-admin-api/v1/environment-cache"
```

This requires the compiler's own certname to be permitted on the `puppetlabs environment-cache` rule in `/etc/puppetlabs/puppetserver/conf.d/auth.conf`. `systemctl reload puppetserver` is a heavier fallback if the admin API proves awkward.

### 12.3 Deploy authorisation

CI needs to run r10k as root on the compilers, which is substantial authority to hand a pipeline. The SSH key is locked to a forced command:

```
command="/usr/bin/sudo /usr/local/sbin/r10k-deploy $SSH_ORIGINAL_COMMAND",
no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty
```

`r10k-deploy.sh` validates its single argument against `^[a-z0-9_]+$` before using it. A leaked CI variable therefore yields a code deploy, not a shell.

### 12.4 Alternatives considered

`webhook-go` on each compiler, listening for GitLab push events, was considered and rejected. It deploys on push rather than on merge, which bypasses the pipeline gates entirely. CI-driven deployment is slower by a few seconds and gates every change.

---

## 13. Secrets management

hiera-eyaml, with PKCS7 keys.

| Key | Location | Who has it |
|---|---|---|
| Public | Committed to the control repository | Everyone, including CI |
| Private | `/etc/puppetlabs/puppet/eyaml/` on compilers only | Platform team, compilers |

Encryption is available to anyone; decryption is available only to the compilers at catalog compile time. CI can validate that an encrypted value is well-formed but cannot read it.

```bash
eyaml encrypt -l 'profile::app::db_password' -s 'hunter2'
```

The resulting block goes into the matching `.eyaml` file at the appropriate hierarchy level. Every hierarchy level has an `.eyaml` counterpart, so a secret can be set per node, per role, or estate-wide.

Parameters receiving secrets are typed `Sensitive[String[1]]` so their values do not appear in reports or logs.

---

## 14. Monitoring, dashboards, and retention

### 14.1 Dashboard

Either **Puppetboard** (Vox Pupuli, Python/Flask, purpose-built, stateless) or **OpenVox View** (single Go binary, includes a CA interface for viewing, signing and revoking certificates). Both read the same OpenVoxDB API, so switching later costs nothing. OpenVox View's certificate management is genuinely useful at this fleet size; Puppetboard is more battle-tested.

Foreman was considered and rejected for this build. It brings an ENC, provisioning and host lifecycle management along with its own PostgreSQL database and an active/passive HA story. If classification or provisioning requirements emerge later it is the natural next step, and Foreman gained OpenVox support in its modules in January 2026.

### 14.2 Server health metrics

Install `puppetlabs/puppet_operational_dashboards` (Telegraf → InfluxDB → Grafana). This is the view that explains **why** runs are failing, which the dashboard does not show:

- JRuby pool saturation per compiler — the signal for adding a fourth compiler
- Catalog compile latency, p50 and p95
- OpenVoxDB command queue depth — sustained non-zero means PostgreSQL I/O, not thread count
- JVM heap and garbage collection
- PostgreSQL table sizes and growth rate

### 14.3 Retention

At a 30-minute interval, 1,600 nodes produce roughly 1.1 million reports over 14 days. Resource events dominate the volume and age out fastest.

```
# /etc/puppetlabs/puppetdb/conf.d/database.conf
[database]
report-ttl          = 7d
resource-events-ttl = 2d
node-purge-ttl      = 14d

[command-processing]
threads = 6
```

Seven days of reports covers essentially every real investigation. Monitor table growth for the first month and adjust.

Six command-processing threads absorb roughly 2.7 commands per second (facts, catalog and report per run across 1,600 nodes at 30 minutes).

---

## 15. Operational runbooks

### 15.1 Onboard a node

1. Provisioning writes `/etc/puppetlabs/puppet/csr_attributes.yaml` with `challengePassword`, `pp_role` and `pp_datacenter` — **before** the first agent run.
2. Install the release package for the platform, then `openvox-agent`, from the internal mirror.
3. Write `/etc/puppetlabs/puppet/puppet.conf` with `server`, `ca_server`, `runinterval`, `splay`, `splaylimit`.
4. `systemctl enable --now puppet`.
5. The CA autosigns if the shared secret and role validate.

If the role does not yet exist, step 5 succeeds but the first catalog compile fails with the message from `site.pp`. That is the intended behaviour.

### 15.2 Add a role

1. Control repo: create `site-modules/role/manifests/<role>.pp` inheriting `role::base`.
2. Control repo: create `data/role/<role>.yaml` for platform-owned values.
3. Control repo: add the role to the autosign allowlist.
4. App data repo, if the team owns configuration: create `data/role/app_<name>.yaml`.
5. Add a representative certname to `diff_nodes.txt` in whichever repo will change it most often.

### 15.3 Support a new OS release

1. Mirror the new `openvox8-release` repository internally.
2. Create `data/os/<Name>-<major>.yaml` with the repository definition.
3. If family-wide values differ, adjust `data/os/<Family>.yaml`.
4. Add the platform to the `rspec-puppet` fact set.

No manifest change is required. If one appears necessary, §9 has been violated somewhere.

### 15.4 Patch or reboot a compiler

```bash
# On lb1 and lb2
echo "disable server openvox/vox2" | socat stdio /var/run/haproxy.sock
# Wait for connections to drain (up to one run interval)
# ... patch, reboot ...
puppet agent -t                    # verify the compiler serves itself
curl -k https://vox2:8140/status/v1/simple   # expect: running
echo "enable server openvox/vox2" | socat stdio /var/run/haproxy.sock
```

Two compilers carry the fleet comfortably. Do not remove two at once.

### 15.5 CA loss and recovery

The CA is the only irreplaceable component. Recovery:

1. Build a replacement host from the control repository with `pp_role: openvox_ca`.
2. Restore `/etc/puppetlabs/puppetserver/ca` and `/etc/puppetlabs/puppet/ssl` from backup.
3. Verify: `puppetserver ca list --all`.
4. Repoint the `puppetca.example.com` CNAME.
5. Confirm signing works end to end with a scratch node.

Catalog compilation is unaffected throughout — only certificate issuance and CRL refresh are interrupted. There is no urgency beyond onboarding being blocked.

**If the CA backup is also lost**, every node must be re-certified by hand. This is the scenario the backup regime exists to prevent, and the reason the restore is tested before go-live rather than after an incident.

### 15.6 OpenVoxDB or data node loss

Agent runs continue and continue enforcing configuration, because `soft_write_failure = true`. What stops:

- Reports, facts and inventory stop updating
- Dashboard shows stale data
- Exported resources and `puppetdb_query()` fail (avoid depending on these)

Recovery is to rebuild the host from the control repository and let the fleet repopulate. Facts and catalogs return within one run interval; report history before the failure is gone. Restore PostgreSQL from backup only if that history is needed.

### 15.7 Roll back a bad deploy

`git revert` on `production` and let the pipeline deploy. This is preferred over resetting the branch, which breaks the audit trail and confuses anyone with the old ref checked out.

For an urgent stop, disable the agent fleet-wide before reverting:

```bash
# Via OpenBolt across the inventory
puppet agent --disable "reverting <MR>"
```

Re-enable after the revert has deployed and been verified on one host.

### 15.8 Add a fourth compiler

1. Build the host with `pp_role: openvox_compiler`.
2. Generate its certificate with `puppet.example.com` in the SANs.
3. Add it to `profile::openvox::loadbalancer::compilers` in `data/role/openvox_lb.yaml`.
4. Add it to the `deploy:production` matrix in `.gitlab-ci.yml`.
5. Add its host key to `SSH_KNOWN_HOSTS`.

---

## 16. Backup and disaster recovery

| Asset | Method | Frequency | RPO | Tested |
|---|---|---|---|---|
| CA keys and certificates | `tar` of `/etc/puppetlabs/puppetserver/ca` + `/etc/puppetlabs/puppet/ssl`, offsite | Daily | 24 h | **Before go-live, then quarterly** |
| eyaml private key | Offline secret store | On rotation | — | On rotation |
| Git repositories | GitLab backup | Per GitLab policy | Per GitLab policy | Per GitLab policy |
| PostgreSQL / OpenVoxDB | `pgBackRest` or nightly dump + WAL | Daily | 24 h | Quarterly |
| Compiler configuration | None — rebuilt from Puppet code | — | — | Implicitly, on every rebuild |

The CA backup is the only entry that matters unconditionally. Restore it onto a spare VM once, before go-live, and confirm it signs a certificate. An untested backup is a rumour.

Everything else in this platform rebuilds from packages plus Git.

---

## 17. Failure modes

| Failure | Impact | Fleet still converges? | Action |
|---|---|---|---|
| One compiler down | Capacity 12 JRubies vs ~7 needed | Yes | Patch or rebuild at leisure |
| Two compilers down | Capacity 6 vs ~7 needed | Degraded | Relax run interval; restore urgently |
| All compilers down | No new catalogs | No — existing config persists but does not update | Major incident |
| HAProxy VIP holder down | keepalived moves the VIP | Yes, brief interruption | Investigate |
| Both load balancers down | Agents cannot reach any compiler | No | Major incident; consider a temporary DNS A record to one compiler |
| CA down | No new certs, no CRL refresh | Yes | Restore from backup; not urgent |
| OpenVoxDB down | No reports, facts or dashboard | Yes, via `soft_write_failure` | Rebuild |
| PostgreSQL disk full | OpenVoxDB write failures | Yes, via `soft_write_failure` | Tighten TTLs; extend disk |
| GitLab down | No deploys | Yes, on existing code | Wait |
| Deploy reaches 2 of 3 compilers | Catalogs differ by compiler | Inconsistently | Pipeline fails the job; re-run |
| Environment cache not flushed | Old code served indefinitely | Yes, but with old code | Flush manually; fix the deploy script |

The recurring theme: almost everything degrades to "the fleet keeps enforcing its current configuration but stops receiving updates". That is the correct failure mode, and `soft_write_failure` is what preserves it for the data tier.

---

## 18. Build order

Each step should be verified before the next begins.

| # | Step | Verification |
|---|---|---|
| 1 | Internal package mirrors for Ubuntu and EL | `apt install openvox-agent` succeeds from a test host |
| 2 | GitLab group, both repositories, protected branches, job token allowlist | A trivial merge request runs the pipeline |
| 3 | `vox1` by hand: `openvox-server`, CA enabled, certificate with all SANs | `puppetserver ca list --all` |
| 4 | Control repo bootstrapped; `vox1` manages itself | `puppet agent -t` on `vox1` is idempotent |
| 5 | `voxdata1`: PostgreSQL, OpenVoxDB, dashboard | Reports from `vox1` appear in the dashboard |
| 6 | eyaml keys generated and distributed | An encrypted value decrypts during compile |
| 7 | `vox2` and `vox3` from the control repo | Each serves a catalog directly |
| 8 | `lb1` and `lb2`; VIP live | `puppet agent -t --server puppet.example.com` from a test host |
| 9 | CI deploy path end to end | A merge to `production` lands on all three compilers |
| 10 | `voxtest1` and feature branch deploys | A branch environment appears and is purged on close |
| 11 | App data repo, allowlist, validation, catalog diff | An invalid key fails the pipeline with a useful message |
| 12 | Autosign policy and provisioning integration | A new host onboards with no manual signing |
| 13 | Monitoring and Grafana dashboards | JRuby saturation visible |
| 14 | **CA backup restore test** | A restored CA signs a certificate |
| 15 | Agent rollout in waves | Compile latency stable between waves |

Roll agents out in waves — by datacenter or by role — and watch compile latency and JRuby saturation after each wave rather than onboarding 1,600 hosts at once.

There is a bootstrap ordering constraint at steps 3 and 4: `vox1` must be built by hand or with OpenBolt before it can manage itself. Do not attempt to bootstrap the CA from a catalog it has not yet compiled.

---

## 19. Open items

Items that need verification or a decision before or during the build.

| # | Item | Owner | Notes |
|---|---|---|---|
| 1 | Pin exact module versions in `Puppetfile` | Platform | Versions in the skeleton are placeholders |
| 2 | Verify `theforeman/puppet` parameter names against the pinned version | Platform | Names shift across major releases; `server_foreman => false` is required |
| 3 | Confirm the internal YUM mirror path structure | Platform | `data/os/RedHat-*.yaml` `baseurl` assumes `<mirror>/openvox8/el/<major>/$basearch` |
| 4 | Choose Puppetboard or OpenVox View | Platform | Both read the same API; switching later is cheap |
| 5 | Tune `catalog:diff` in the app data pipeline | Platform | Cache `modules/`; keep `allow_failure` until stable |
| 6 | Confirm `auth.conf` permits the environment-cache admin API for each compiler's own certname | Platform | Otherwise the deploy script's flush fails |
| 7 | Decide whether to strip parameter defaults so a missing Hiera key is a hard failure | Platform | Stricter, but noisier during initial build |
| 8 | Audit control repo git history for plaintext secrets before granting read access | Platform | See §7.3 |
| 9 | Shared secret rotation schedule for autosigning | Platform | Also on provisioning-system compromise |
| 10 | Plan the OpenVox 9 upgrade | Platform | 8.x enters maintenance once 9 branches |

---

## Appendix A — Key configuration files

| File | Host | Purpose |
|---|---|---|
| `/etc/puppetlabs/puppet/puppet.conf` | All | `server`, `ca_server`, `runinterval`, `splay` |
| `/etc/puppetlabs/puppet/csr_attributes.yaml` | All, pre-first-run | `pp_role`, `pp_datacenter`, `challengePassword` |
| `/etc/puppetlabs/puppet/puppetdb.conf` | Compilers | `server_urls`, `soft_write_failure` |
| `/etc/puppetlabs/puppetserver/conf.d/puppetserver.conf` | Compilers | `max-active-instances`, `http-client` timeout |
| `/etc/puppetlabs/puppetserver/services.d/ca.cfg` | Compilers | CA service enabled or disabled |
| `/etc/puppetlabs/puppetserver/conf.d/auth.conf` | Compilers | Admin API authorisation |
| `/etc/sysconfig/puppetserver` or `/etc/default/puppetserver` | Compilers | JVM heap, reserved code cache |
| `/etc/puppetlabs/code/environments/*/environment.conf` | Compilers | `modulepath`, `environment_timeout` |
| `/etc/puppetlabs/puppetdb/conf.d/database.conf` | `voxdata1` | TTLs, command threads |
| `/etc/haproxy/haproxy.cfg` | `lb1`, `lb2` | TCP passthrough listener |

## Appendix B — Reference

- OpenVox project: https://voxpupuli.org/openvox/
- OpenVox documentation: https://docs.openvoxproject.org/
- Package repositories: https://apt.voxpupuli.org, https://yum.voxpupuli.org
- Reference architectures: https://voxpupuli.org/docs/arch_load_balanced/
- Community: `#openvox` on Slack, `#voxpupuli-openvox` on IRC

Upstream Puppet documentation applies to OpenVox except where the projects have diverged; divergences are documented at docs.openvoxproject.org.
