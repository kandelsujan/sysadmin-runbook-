# Rollout model

How a change reaches the fleet. The three business environments — `reg`, `imp`,
`vip` — are criticality tiers, `vip` being the most critical. Each is its own
standing Puppet environment on its own branch. Hosts are pinned to a tier at
build (`environment` in puppet.conf) and never move.

Changes are validated on `reg` first. `imp` and `vip` receive the same change
later, through their own MRs, once it has proven out. Nothing is ever merged
between the three branches.

## The vehicle: module versions

Most changes ride in versioned modules. The module's own `main` branch is the
promotion gate.

```
module feature branch ──> rc tag ──> pinned by reg ──> simmer
                                                          │ looks good
module main  <── merge ──────────────────────────────────┘
     │
  final tag  ──> pinned by imp ──> pinned by vip   (their own MRs, their own timing)
```

Step by step, for a change to the internal module `acme_app`:

1. **Develop** on a feature branch of `puppet-acme_app`. Its own CI runs lint
   and rspec. Tag a release candidate from the branch: `v1.3.0-rc1`.

2. **Validate on reg.** MR to the `reg` branch of the control repo bumping the
   Puppetfile:

   ```ruby
   mod 'acme_app',
     git: 'git@gitlab.example.com:puppet/modules/puppet-acme_app.git',
     tag: 'v1.3.0-rc1'
   ```

   Merge, deploy. The whole reg tier now runs the candidate. Let it simmer for
   long enough to mean something — at least a day, longer if the change
   involves anything periodic (log rotation, cert renewal, cron).

3. **Graduate.** When reg looks clean, merge the module's feature branch to the
   module's `main` and cut the final tag `v1.3.0`. That merge IS the promotion
   decision, recorded in the module's history.

4. **Roll to imp, then vip.** MRs to each branch pinning `tag: 'v1.3.0'`, on
   whatever schedule suits each tier. vip lagging imp by days is normal and
   fine.

5. **Tidy reg.** MR to reg moving its pin from `v1.3.0-rc1` to `v1.3.0` (same
   commit, final name), so all three tiers end on the identical tag.

### Enforced by CI, not memory

`scripts/check-puppetfile-pins.rb` fails the pipeline if:

- any Puppetfile entry is unpinned (all branches), or
- a pre-release tag (`-rc`, `-beta`, `-alpha`) appears anywhere **except the
  reg branch**. Candidate code structurally cannot reach imp or vip.

Never pin a branch name in any tier's Puppetfile. A branch moves under you; a
tag does not.

## Changes that are not modules

Profiles, roles, Hiera data, and Puppetfile bumps live in the control repo and
have no `main` branch to graduate through. These are applied per tier: MR to
reg first, observe, then equivalent MRs to imp and vip.

This is the one place drift can creep in — three hand-made MRs are three
chances to diverge. Two habits keep it contained:

- **Keep site code thin.** Push logic into versioned internal modules wherever
  possible, so most changes ride the tag pipeline and the control branches
  carry mostly Puppetfiles and data.
- **Differences between tiers should be data, not code.** If vip genuinely
  needs stricter values, that belongs in Hiera keyed on `%{environment}` — an
  intentional, reviewable divergence — not in structurally different manifests.

If unexplained divergence between the branches ever becomes a real problem, a
scheduled CI job diffing `site-modules/` across the three branches is the
lightweight fix; it is deliberately not built yet.

## Observing a rollout

Each tier's `.config_version` is the commit of its own branch, which pins its
exact Puppetfile. So "which acme_app is vip running" is always one lookup:

```bash
# On any compiler: what commit is each tier on?
for e in production reg imp vip; do
  printf '%-11s %s\n' "$e" "$(cat /etc/puppetlabs/code/environments/$e/.config_version 2>/dev/null || echo not-deployed)"
done

# What does that commit pin?
git show <sha>:Puppetfile | grep -A2 acme_app
```

And in OpenVoxDB, per-tier health during a reg simmer:

```
nodes[certname, latest_report_status] {
  catalog_environment = "reg" and latest_report_status = "failed"
}
```

## Emergencies

A fix that must reach vip immediately skips the simmer: tag it final, MR
straight to vip (and imp, and reg). The pipeline gates still apply — pinned,
non-prerelease — so the shortcut is fast but never un-reviewed. Backfill reg
with the same tag afterwards so the tiers reconverge.
