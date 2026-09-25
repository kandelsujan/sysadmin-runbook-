# Distributing the nameprod SSH keypair with Puppet

Sep 20, 2026 · @Sujan

## Overview

This document covers distributing a shared `nameprod` SSH keypair to a group of hosts with Puppet. The private key is served from a restricted fileserver mount on the puppetserver. The public key and all per-group configuration come from Hiera.

**What this design gives you**

- The private key never enters git or the control repo.
- The key never appears in the compiled catalog, the agent's catalog cache, or PuppetDB. Only a checksum does.
- Access is controlled by the agent's existing Puppet certificate, so there is no separate credential to distribute.
- Adding a host to the group is a Hiera change only.

**What this design does not solve**

- The same private key sits on disk on every host in the group. Root on any one of them can steal it, and a compromise means rotating everywhere.
- The key is stored unencrypted on the puppetserver. Anyone who is root there, who can become the `puppet` user, who can merge code to the control repo, or who controls certificate issuance can obtain it. Puppetserver backups and VM snapshots contain it too.
- There is no audit trail of who read the key, and no built-in rotation tooling.

These limits come from using a shared key, not from the delivery mechanism. If the group grows or the account gains broad production reach, per-host keys or SSH certificates are the upgrade path.

## Prerequisites

Before starting, confirm:

- **The user account.** This document assumes `nameprod` is created elsewhere in your manifests. If not, add a `user` resource and make the key files depend on it.
- **The certname pattern for the group.** Access control is by certificate name, so a consistent pattern such as `rtdp01.example.com` lets you write one rule that covers hosts you have not built yet. If names are irregular, you will maintain an explicit list.
- **Whether autosign is enabled.** With `autosign = true`, anyone who can reach the CA can request a certificate matching your pattern and be handed the key. We use a policy script, which is the right approach. Confirm it would reject a request for a matching name from an unexpected machine, not just that it approves legitimate ones.
- **How many compile masters you have.** The key file must exist identically on every one of them.
- **Which hosts are not Puppet-managed.** Their `authorized_keys` entries are maintained by hand. List them now, because they are the ones people forget during rotation.

Generate the keypair on a trusted workstation, not on a target host:

```bash
ssh-keygen -t ed25519 -N '' -C 'nameprod' -f id_ed25519
```

## Step 1: Place the private key on the puppetserver

Store it outside the control repo so it never reaches git:

```bash
install -d -o puppet -g puppet -m 0700 \
  /etc/puppetlabs/puppetserver/secrets/nameprod

install -o puppet -g puppet -m 0400 \
  id_ed25519 /etc/puppetlabs/puppetserver/secrets/nameprod/id_ed25519
```

The file must be readable by the user puppetserver runs as, which is `puppet` on standard installs. Confirm it rather than assuming:

```bash
ps -o user= -C java | sort -u
```

If you run compile masters, copy the file to each one with the same ownership and mode. A host that lacks it will fail the file resource with a 404 from its compiler.

Add the path to your puppetserver build or configuration-management process so it survives a rebuild, and record that it exists somewhere your team will find it. A secret that only lives on one server and is documented nowhere becomes an outage when that server is replaced.

## Step 2: Define the fileserver mount

In `/etc/puppetlabs/puppet/fileserver.conf`:

```ini
[secrets]
path /etc/puppetlabs/puppetserver/secrets
```

This makes the directory reachable as `puppet:///secrets/...`.

Do not add `allow` or `deny` lines here. They are ignored on current Puppet versions, and relying on them gives a false sense of protection. Access control belongs in `auth.conf`, which is the next step.

## Step 3: Restrict access in auth.conf

Edit `/etc/puppetlabs/puppetserver/conf.d/auth.conf` and add a rule inside the `rules` array, placed **above** the general file rules:

```hocon
{
    match-request: {
        path: "^/puppet/v3/file_(content|metadata)/secrets/nameprod"
        type: regex
    }
    allow: [ "/^rtdp\\d+\\.example\\.com$/" ]
    sort-order: 300
    name: "nameprod key"
},
```

Points that matter:

- **Both endpoints.** `file_metadata` and `file_content` must both be allowed. The agent checks metadata first, so allowing only content produces a confusing failure.
- **`sort-order`.** Lower numbers are evaluated first. The default file rules sit at 500, so 300 puts yours ahead of them.
- **The regex in `allow`.** Matching a certname pattern means new hosts in the group need no change here. An explicit list of certnames works too and is easier to audit, at the cost of editing this file on every build.
- **Keep it in step with site.pp.** The same regex appears in the site.pp group assignment in section 6.1. Change them together.

Restart puppetserver, then check it parsed:

```bash
systemctl restart puppetserver
tail -50 /var/log/puppetlabs/puppetserver/puppetserver.log
```

A malformed `auth.conf` can stop the service from starting, so have a second terminal open and a copy of the original file.

## Step 4: Test access before writing any manifest

From a host that should have access:

```bash
curl -s -w '%{http_code}\n' -o /dev/null \
  --cert /etc/puppetlabs/puppet/ssl/certs/$(hostname -f).pem \
  --key  /etc/puppetlabs/puppet/ssl/private_keys/$(hostname -f).pem \
  --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
  "https://puppet.example.com:8140/puppet/v3/file_metadata/secrets/nameprod/id_ed25519?environment=production"
```

Expect `200`.

Now run the identical command from a host that should **not** have access, and expect `403`.

This negative test is the step people skip, and it is the one that catches a misordered rule or a regex that matches more than you intended. A rule that is too permissive fails silently, because everything appears to work.

If you get `404`, the mount or the file path is wrong. If you get `403` from a host that should be allowed, check the rule's `sort-order` against the rules above it.

## Step 5: Extend the sshkey module

Add a second parameter for keypairs, leaving the existing root public-key logic untouched. Everything about the keypair comes from Hiera, including the fileserver URL, so the module stays generic and can serve other users later.

```puppet
class sshkey (
  Hash $authorized_keys = {},   # existing root logic
  Hash $keypairs        = {},   # new
) {

  # ...existing ssh_authorized_key resources, unchanged...

  $keypairs.each |String $user, Hash $kp| {

    $home     = pick($kp['home'], "/home/${user}")
    $key_type = pick($kp['key_type'], 'ed25519')

    file { "${home}/.ssh":
      ensure => directory,
      owner  => $user,
      group  => $user,
      mode   => '0700',
    }

    file { "${home}/.ssh/id_${key_type}":
      ensure    => file,
      owner     => $user,
      group     => $user,
      mode      => '0600',
      source    => $kp['private_key_source'],
      show_diff => false,
      require   => File["${home}/.ssh"],
    }

    file { "${home}/.ssh/id_${key_type}.pub":
      ensure  => file,
      owner   => $user,
      group   => $user,
      mode    => '0644',
      content => "${kp['public_key']}\n",
      require => File["${home}/.ssh"],
    }
  }
}
```

Notes:

- `pick` requires stdlib.
- `source` carries only a URL, so the catalog holds a checksum rather than the key. This is the whole point of the design. Do not switch this to `content` with the key inlined.
- `show_diff => false` keeps the file out of agent logs and reports.
- If `nameprod` is managed in the catalog, add `require => User[$user]` to the directory resource.
- The public key is not secret, so it stays inline in Hiera.

## Step 6: Distributing it with Hiera data

This is where the group scoping happens. Root's public keys stay in `common.yaml` as they are today; the nameprod keypair is added at a group level that only the rtdp hosts see.

### 6.1 Derive the group from the certname, server-side

The group level decides who Puppet tries to give the key to, so it must come from something the node cannot change. A plain fact such as `%{facts.server_group}` is supplied by the node and editable by anyone with root on it, so a compromised host could claim to be in the rtdp group.

We don't use trusted extensions, because anything baked into the certificate means reissuing it whenever that attribute changes. Instead, compute the group on the puppetserver from `$trusted['certname']`, which is taken from the verified certificate and cannot be spoofed.

In `manifests/site.pp`, at top scope and before any node definitions or class declarations:

```puppet
$server_group = $trusted['certname'] ? {
  /^rtdp\d+\.example\.com$/ => 'rtdp',
  default                   => undef,
}
```

Then reference it in `hiera.yaml`:

```yaml
---
version: 5

defaults:
  datadir: data
  data_hash: yaml_data

hierarchy:
  - name: "Per-node"
    path: "nodes/%{trusted.certname}.yaml"

  - name: "Server group"
    path: "group/%{::server_group}.yaml"

  - name: "Common"
    path: "common.yaml"
```

When `$server_group` is undef the path resolves to `group/.yaml`, which does not exist, so non-rtdp hosts simply skip that level.

**Keep the regex identical to the one in auth.conf.** The site.pp regex decides who Puppet tries to give the key to; the `auth.conf` rule from Step 3 decides who the puppetserver will actually serve it to. If they drift apart you get either a host that fails with a 403, or worse, a rule broader than the classification. Consider a comment in both files pointing at the other.

If you already use an ENC, it can set `server_group` as a top-scope parameter instead of site.pp. ENC output is generated server-side, so it is equally safe.

**Certname is now the only control, so autosign guards the key.** Your autosign policy script is what stops someone requesting a certificate named `rtdp99.example.com` from an unexpected machine. Check that it would reject such a request, not just that it accepts legitimate ones: ideally it verifies a CSR attribute such as a challenge password, or the requesting source, rather than trusting the name alone.

### 6.2 The group data file

`data/group/rtdp.yaml`:

```yaml
---
sshkey::keypairs:
  nameprod:
    home: /home/nameprod
    key_type: ed25519
    public_key: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... nameprod'
    private_key_source: 'puppet:///secrets/nameprod/id_ed25519'
```

There is no secret in this file, so it is safe in git. It holds a pointer to the key, not the key.

Paste the public key on one line, without a trailing newline in the YAML. The module adds the newline.

### 6.3 Leave common.yaml alone

`data/common.yaml` keeps only what it has now:

```yaml
---
sshkey::authorized_keys:
  root:
    # existing root public keys
```

Hosts outside the rtdp group get the parameter default of `{}` for `keypairs`, so the new code is a no-op for them. Nothing changes for the rest of your estate.

### 6.4 Watch the merge behaviour

By default Hiera returns the first value it finds, so a key defined at the group level **replaces** the common value rather than combining with it. This bites in one specific case: if nameprod also needs an `authorized_keys` entry on the rtdp hosts, adding `sshkey::authorized_keys` to `group/rtdp.yaml` will hide the root entry from `common.yaml`, and root's keys will silently disappear from those hosts.

Fix it by declaring the merge strategy in `common.yaml`:

```yaml
lookup_options:
  sshkey::authorized_keys:
    merge: deep
  sshkey::keypairs:
    merge: hash
```

`deep` merges the inner hashes, so root's keys from `common.yaml` and nameprod's from the group file both survive. Use `hash` for `keypairs` if you ever define a keypair at more than one level.

After changing merge behaviour, check the result on a node before trusting it:

```bash
puppet lookup sshkey::authorized_keys \
  --node rtdp01.example.com --explain
```

The `--explain` output shows each level considered and how values were merged, which is far faster than inferring it from a failed run.

### 6.5 Adding a host later

Once this is in place, bringing a new rtdp host into the group means:

1. Give it a certname matching the rtdp pattern, and let your autosign policy approve it.
2. Run the agent.

No change to the module, the Hiera data, site.pp, or `auth.conf`, as long as the name fits the pattern. A host whose name doesn't fit needs both regexes widened, together.

## Step 7: Verify on one host

Classify a single rtdp host first. Run the agent and check three things.

**The lookup resolves as expected:**

```bash
puppet lookup sshkey::keypairs --node rtdp01.example.com --explain
```

**The key arrived intact:**

```bash
puppet agent -t
ssh-keygen -y -f /home/nameprod/.ssh/id_ed25519
```

`ssh-keygen -y` derives the public key from the private one. If it prints a key, the file is valid and complete. If it complains about an invalid format, the file was truncated or mangled in transit.

**The catalog is clean:**

```bash
grep -c 'BEGIN OPENSSH' \
  /opt/puppetlabs/puppet/cache/client_data/catalog/*.json
```

This must return `0`. Searching the same file for `secrets/nameprod` should find the source URL. That is the difference this design buys you, so confirm it rather than assuming it.

Finally, test that nameprod can actually authenticate somewhere before rolling out:

```bash
sudo -u nameprod ssh -i /home/nameprod/.ssh/id_ed25519 \
  nameprod@target.example.com true
```

## Step 8: Harden the puppetserver

The key is only as protected as the server holding it.

- **Lock the puppet account.** `passwd -S puppet` should show it locked, with a nologin shell. Then becoming `puppet` requires root.
- **Audit sudo rules.** Look through `/etc/sudoers.d/` for anything with a runas spec of `(ALL)` or `(puppet)`, which would let a non-root operator read the file.
- **Log reads.** Add an auditd watch:

  ```
  -w /etc/puppetlabs/puppetserver/secrets -p r -k nameprod_key
  ```

  This gives you the detection capability the design otherwise lacks.
- **Encrypt backups.** The secrets directory will be in them. Check whether VM snapshots are also in scope.
- **Test the autosign policy script** against a request for a rtdp-pattern certname from a host that shouldn't get one. Since group membership is derived from the certname, this script is what stands between an unexpected machine and the key.
- **Protect the control repo.** Anyone who can merge code can write a manifest that copies the key somewhere readable. Branch protection and required review are the only controls here; file permissions do not help.

Be honest about the resulting trust boundary. It is not "root only". It is root or `puppet` on every puppetserver and compile master, plus everyone with code-merge rights, plus whoever controls certificate issuance, plus anyone with the backups.

## Step 9: Restrict the key on the receiving end

This is the highest-value control in the document, and it is independent of how the key is delivered. It limits what a stolen key can do.

On every host nameprod logs in to, Puppet-managed or not, write the `authorized_keys` entry with options:

```
from="10.0.5.0/24",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3... nameprod
```

If nameprod runs a fixed job rather than arbitrary commands, add a forced command:

```
command="/usr/local/bin/nameprod-runner",from="10.0.5.0/24",no-pty,... ssh-ed25519 AAAAC3... nameprod
```

With these in place, a key copied off a compromised host is useless from outside your network and cannot be used for an interactive shell or as a forwarding pivot.

For Puppet-managed targets, `ssh_authorized_key` takes the options as a parameter:

```puppet
ssh_authorized_key { 'nameprod':
  user    => 'nameprod',
  type    => 'ssh-ed25519',
  key     => $public_key,
  options => [
    'from="10.0.5.0/24"',
    'no-pty',
    'no-port-forwarding',
    'no-agent-forwarding',
    'no-X11-forwarding',
  ],
}
```

For the hosts not managed by Puppet, keep a list of them with the `authorized_keys` path on each. That list is what makes rotation possible.

## Rotation runbook

The order matters. Adding the new public key everywhere **before** replacing the private key is what stops you locking nameprod out mid-rotation.

1. Generate a new keypair on a trusted workstation.
2. Add the new public key to every target's `authorized_keys`, **alongside** the existing one. Both keys are accepted during the transition. Do not forget the hosts that are not Puppet-managed.
3. Verify the new key works against a sample of targets, using `ssh -i` with the new private key.
4. Replace the file on the puppetserver, and on every compile master.
5. Update `public_key` in `data/group/rtdp.yaml`.
6. Let the agents converge, or force a run on the group.
7. Confirm on each host with `ssh-keygen -y -f /home/nameprod/.ssh/id_ed25519` and compare the fingerprint to the new key.
8. Remove the old public key from every target.

Rotate on a schedule, and immediately on any suspected compromise of a host in the group. Because step 2 and step 8 touch manually-managed hosts, keep that list current.

### When to move past this design

A shared key is a reasonable choice for a small group with a restricted account. Revisit it when any of these become true:

- The group grows beyond a couple of dozen hosts.
- nameprod gains broad reach into production.
- You acquire an audit requirement for who accessed the key.
- Rotation has been deferred more than once because it is painful.

The upgrade paths, in increasing order of effort: per-host keypairs generated locally and distributed as public keys via exported resources; or SSH certificates, where a CA signs each host's public key and targets trust the CA through `TrustedUserCAKeys`. Certificates suit an estate with hosts outside Puppet's control, because each one needs the CA public key installed only once and then never needs touching again.

## Troubleshooting

**403 on the file during an agent run.** The `auth.conf` rule did not match. Check the certname against your regex, and check `sort-order` against the rules above it. A rule placed below the default file rules never fires.

**404 on the file.** The mount name or path is wrong. `puppet:///secrets/nameprod/id_ed25519` maps to `<mount path>/nameprod/id_ed25519`. Also check the file exists on the compile master the agent actually reached, not just the one you edited.

**Agent gets metadata but not content.** Only one of the two endpoints is allowed. The regex in Step 3 covers both with `file_(content|metadata)`.

**The key file is created but SSH rejects it.** Usually a missing trailing newline, or wrong permissions. `chmod 0600` and confirm ownership. `ssh-keygen -y -f <file>` tells you whether the key itself parses.

**Permission denied reading the source, in the puppetserver log.** The file is not readable by the `puppet` user. Check ownership, and the mode on the parent directory as well as the file.

**Root's keys vanished from the rtdp hosts.** The merge problem from section 6.4. Add `lookup_options` with `merge: deep` in `common.yaml`.

**Nothing happens at all on a host.** The Hiera lookup returned an empty hash. Run `puppet lookup sshkey::keypairs --node <certname> --explain` and check the group level resolved. The usual cause is a certname that doesn't match the site.pp regex, or `$server_group` being assigned after the class is declared. It fails silently, because an empty hash is a valid value.

**Works on one host, fails on another.** Different compile masters. Confirm the key file and `auth.conf` are identical on all of them.
