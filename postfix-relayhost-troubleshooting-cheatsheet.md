# Postfix Troubleshooting Cheatsheet — Client vs Relayhost

Your topology has **two Postfix hops**, and every complaint maps to a failure at one of them:

```
User app / MUA  →  [CLIENT] Postfix (routes via transport_maps)  →  [RELAYHOST] Postfix (your team's)  →  Internet MX
```

Routing here is done with a **transport file** (`transport_maps`), not the `relayhost` parameter. That means routing is **per recipient domain**: a broken or incomplete transport map can send *some* domains through the relay and others direct-to-MX — which is why "mail to domain A works but domain B doesn't" is a routing question before it's a delivery question.

Every command below is tagged with where to run it:

- **[CLIENT]** — the Linux box the user's mail originates from (app server, workstation Postfix)
- **[RELAYHOST]** — the smarthost your team manages
- **[EITHER]** — same command, run on whichever hop you're inspecting

**The single most important diagnostic question:** did the message make it from the client to the relayhost? Find the queue ID on the client, confirm `status=sent (250 ...)` with `relay=<your-relayhost>` in the client's log, then pick up the trail on the relayhost. Where the trail stops tells you which machine owns the problem.

---

## 0. First step — reproduce it yourself with a test email

**[CLIENT]** — before reading configs or guessing, send a canary message *from the same box the user's mail originates on* and trace it. This turns a vague complaint into a queue ID you own, with a timestamp you know:

```bash
# Inject through the REAL path (pickup → qmgr → transport map → relay),
# exactly like the user's app does:
echo "canary body" | mail -s "canary $(hostname) $(date +%s)" your-external-address@gmail.com

# Immediately grab the queue ID and watch it:
tail -f /var/log/mail.log        # or: journalctl -u postfix -f
```

Interpret what you see within ~60 seconds:

| Result | Meaning | Go to |
|---|---|---|
| `relay=<your-relayhost>, status=sent (250 ... queued as X)` | Client hop is healthy — carry queue ID `X` to the **[RELAYHOST]** and keep tracing | §1 |
| `relay=<some-remote-mx>` (not your relay) | Transport map missed this domain — routing bug, not delivery | §3 |
| `status=deferred (...)` | Read the reason in parentheses — connection, TLS, or auth to the relay | §5 |
| Rejected immediately at injection | Client's own smtpd/restrictions problem | §5 |
| Test arrives in your inbox but the *user's* mail doesn't | Problem is specific to their sender/recipient/message — diff their queue ID against yours | §1 |

**Send three canaries, not one** — with transport maps, each recipient domain can take a completely different route, so each canary tests a different line of the transport file:

```bash
STAMP="$(hostname)-$(date +%s)"
echo "canary-int $STAMP"  | mail -s "canary-int $STAMP"  you@yourcompany.com          # internal route
echo "canary-ext $STAMP"  | mail -s "canary-ext $STAMP"  you@gmail.com                # external/catch-all route
echo "canary-fail $STAMP" | mail -s "canary-fail $STAMP" test@the-failing-domain.com  # the route the user reports broken
```

Typical transport file behind those three:

```
yourcompany.com   smtp:[mail.internal.example]:25    ← internal canary tests this
special-corp.com  smtp:[partner-gw.example]:25       ← a "failing domain" canary might land here
*                 smtp:[relay.internal.example]:587  ← external canary tests this
```

Read the matrix:

| Internal | External | Diagnosis |
|---|---|---|
| OK | fails | Internal route fine; problem is the relay/catch-all path — client→relay connectivity/auth (§4, §5) or the relayhost's outbound leg (§1 trace) |
| fails | OK | Relay path fine; the *internal* transport entry or the internal mail server is the problem — check that entry's nexthop, and the internal MTA itself |
| fails | fails | Postfix-wide on the client: service down, queue jammed, local smtpd restrictions, or the transport `.db` is stale/broken (§0.5, §3) |
| OK | OK, but the user's specific domain fails | Per-domain route: missing/wrong transport entry, subdomain gap, or that one nexthop is down — `postmap -q their-domain` (§3) |

More tips:
- `mail` reproduces the user's path (it hands off to Postfix's local submission just like their apps do); `swaks --server relay:587` **bypasses** the local Postfix and transport map entirely. Use `mail` to *reproduce*, swaks to *isolate* a specific hop (§4). If `mail` fails but swaks straight to the relay works, the problem is on the client (routing, local restrictions) — not the relay.
- The `$STAMP` in each canary's subject lets you match them unambiguously in logs on both hops (`grep "$STAMP"` won't work in mail.log — subjects aren't logged by default — but it identifies them in the destination inbox; in the logs, match by timestamp and recipient instead, or grep the queue IDs `mail` triggers in `tail -f`).
- Check the log's `relay=` field for each canary — it tells you which transport entry actually fired, which beats reasoning about what the map *should* do.

---

## 0.5. 60-second health triage

**[EITHER]** — run on both hops, compare:

```bash
systemctl status postfix
postfix check                        # silence = good
mailq | tail -5
postqueue -p | grep -c '^[A-F0-9]'   # rough queued count
tail -50 /var/log/mail.log           # or: journalctl -u postfix -n 50
```

Decision tree:
- Mail stuck in **client** queue → client can't reach/authenticate to your relayhost → §3, §4
- Mail flows to relayhost but stuck in **relayhost** queue → relayhost can't deliver to the internet → §6
- Client rejects the user's app immediately → client smtpd restrictions → §5
- Relayhost rejects the client (`554 Relay access denied` in client logs) → relayhost access control → §5

---

## 1. Trace one message across both hops

**[CLIENT]** — find the message and confirm handoff:

```bash
grep -i 'to=<user@example.com>' /var/log/mail.log
grep CLIENT_QUEUEID /var/log/mail.log
```

Healthy handoff line on the client:
```
smtp ... to=<...>, relay=relay.internal.example[10.0.0.5]:587, status=sent (250 2.0.0 Ok: queued as RELAY_QUEUEID)
```

That `queued as RELAY_QUEUEID` is gold — it's the queue ID on the relayhost.

**[RELAYHOST]** — pick up the trail:

```bash
grep RELAY_QUEUEID /var/log/mail.log
# or find it by client hostname/IP if you don't have the ID:
grep 'client=clientbox.internal' /var/log/mail.log | grep -i 'user@example.com'
```

Healthy final delivery on the relayhost:
```
smtp ... to=<...>, relay=aspmx.l.google.com[142.x.x.x]:25, status=sent (250 ...)
```

**[EITHER]** — inspect a queued message and its deferral reason:

```bash
postqueue -p          # deferral reason in parentheses
postcat -q QUEUEID    # full headers/body
```

**Ownership rule:** if the client log shows `250 Ok: queued as ...` from your relayhost, the client box is done and innocent. Everything after that is relayhost territory.

---

## 2. Queue management

**[EITHER]** — identical commands, but think about which queue you're touching:

```bash
postqueue -p                  # list queue
qshape deferred               # deferred by destination domain & age
postqueue -f                  # flush all
postqueue -i QUEUEID          # retry one
postsuper -d QUEUEID          # delete one
postsuper -h QUEUEID          # hold / -H release
postsuper -r ALL              # requeue (re-evaluates against current config)
```

- On a **[CLIENT]**, `qshape deferred` showing everything piled on *one* destination — your relayhost — means a client→relay problem.
- On the **[RELAYHOST]**, `qshape deferred` spread across many internet domains means an outbound problem (reputation, DNS, throttling); piled on one domain means that provider is deferring you.
- After a config fix: `postfix reload` then `postsuper -r ALL` on the affected hop.
- Beware the thundering herd: after relayhost downtime, dozens of clients flushing at once can overwhelm it. Prefer letting normal retry schedules drain, or flush clients in batches.

---

## 3. Configuration — what belongs where

**[CLIENT]** `main.cf` — routing via a **transport map** (no `relayhost` set):

```
transport_maps = hash:/etc/postfix/transport
smtp_sasl_auth_enable = yes                       # if the relay requires auth
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
inet_interfaces = loopback-only                   # typical satellite: accept local mail only
mydestination =                                   # deliver nothing locally, relay everything
```

`/etc/postfix/transport` — routes by **recipient domain**, most-specific match wins:

```
# domain            transport:nexthop
example.com         smtp:[relay.internal.example]:587
.example.com        smtp:[relay.internal.example]:587   # subdomains — NOT matched by the line above!
partnercorp.com     smtp:[partner-gw.example]:25        # per-domain exception
*                   smtp:[relay.internal.example]:587   # catch-all: everything else via the relay
```

Then: `postmap /etc/postfix/transport && postfix reload`

Transport-map gotchas (these cause most "works for domain A, not domain B" tickets):
- **No `*` catch-all = mail for unlisted domains goes direct-to-MX from the client.** On a locked-down network that means `Connection timed out` for every domain not in the file. If policy is "everything via the relay," the `*` line is mandatory.
- **`example.com` does not match `sub.example.com`.** You need a separate `.example.com` line (or `parent_domain_matches_subdomains = ...` including `transport_maps`, but explicit dot-entries are clearer).
- **Forgot `postmap` after editing** → Postfix still reads the old `.db` file; the text file is never consulted directly. `ls -l /etc/postfix/transport*` — the `.db` must be newer.
- **Brackets in the nexthop** (`[host]`) suppress MX lookup — you want them for internal relays.
- **Precedence:** `transport_maps` overrides `relayhost` per-domain. Since you don't set `relayhost`, the transport file (plus its `*` entry) *is* your entire routing policy — treat it as such in change control.
- `sasl_passwd` keys must match the transport **nexthop** exactly, brackets and port included:
  ```bash
  postmap -q "[relay.internal.example]:587" hash:/etc/postfix/sasl_passwd
  ```
- Config/transport-file drift across the client fleet is common — diff both `postconf -n` **and** the transport file against your config-management source.

**[CLIENT]** — verify what route a domain will actually take:

```bash
postmap -q example.com hash:/etc/postfix/transport     # exact-domain lookup
postmap -q sub.example.com hash:/etc/postfix/transport # returns nothing? subdomain gap!
postmap -q '*' hash:/etc/postfix/transport             # is there a catch-all?
postconf transport_maps                                # is the map even active?
```

An empty `postmap -q` result for a complaining user's recipient domain, with no `*` entry, is your smoking gun: that domain is being delivered direct-to-MX, not through the relay.

**[RELAYHOST]** `main.cf` — accepting from clients, delivering to the world:

```
mynetworks = 127.0.0.0/8 10.0.0.0/8               # client subnets allowed to relay
smtpd_relay_restrictions = permit_mynetworks,
                           permit_sasl_authenticated,
                           reject_unauth_destination
smtpd_tls_cert_file = /etc/ssl/certs/relay.crt    # cert clients validate against
smtpd_tls_key_file  = /etc/ssl/private/relay.key
smtpd_sasl_auth_enable = yes                      # if clients authenticate
message_size_limit = 26214400                     # must be >= what clients send
# Outbound routing: direct-to-MX by default. If the relayhost itself uses a
# transport file to route certain domains (partner gateways, SES for bulk, etc.):
transport_maps = hash:/etc/postfix/transport
```

If the relayhost has its own transport file, all the **[CLIENT]** transport-map gotchas above apply here too — including the subdomain and stale-`.db` traps. A relayhost transport file typically looks like:

```
partnercorp.com     smtp:[secure-gw.partner.example]:25   # forced route to a partner gateway
bulk.yourdomain.com smtp:[email-smtp.us-east-1.amazonaws.com]:587
# no * entry → everything else goes direct-to-MX (normal for a relayhost)
```

Relayhost gotchas:
- If `mynetworks` misses a new client subnet → clients see `554 5.7.1 Relay access denied`.
- If your TLS cert expires or the hostname doesn't match what clients configured → clients log `certificate verification failed` and defer everything.
- `master.cf`: make sure the `submission` (587) service is enabled if clients connect there — port 25 and 587 have separate restriction chains.
- If the relayhost itself chains to an external provider (SES, Mailgun, corporate gateway), then the relayhost *also* acts as a client toward that provider — apply all the **[CLIENT]** checks to it for that leg.

**[EITHER]** — inspection:

```bash
postconf -n                              # all non-default settings
postconf transport_maps mynetworks       # spot-check routing + access params
postconf -n | grep -E 'transport|relay|smtp_|smtpd_'
ls -l /etc/postfix/transport*            # .db newer than the text file?
```

---

## 4. Manual path testing

**[CLIENT]** → first confirm which route the recipient domain resolves to, then test that route:

```bash
postmap -q recipientdomain.com hash:/etc/postfix/transport || \
postmap -q '*' hash:/etc/postfix/transport      # what nexthop applies to this recipient?
nc -vz relay.internal.example 587
dig +short relay.internal.example              # does DNS resolve correctly from THIS box?
openssl s_client -connect relay.internal.example:587 -starttls smtp -brief
    # verify the cert chain and that EHLO shows AUTH/STARTTLS
swaks --to canary@example.com --from app@yourdomain.com \
      --server relay.internal.example:587 --tls \
      --auth LOGIN --auth-user 'relayuser' --auth-password 'xxxx'
```

**[RELAYHOST]** → test toward the internet:

```bash
dig +short MX gmail.com                        # DNS resolution outbound
nc -vz aspmx.l.google.com 25                   # is outbound 25 open? (clouds often block it)
swaks --to yourpersonal@gmail.com --from noreply@yourdomain.com \
      --server aspmx.l.google.com:25           # raw direct-MX delivery test
# Reputation / DNS hygiene for the relayhost's egress IP:
dig +short -x YOUR_EGRESS_IP                   # PTR must exist and match HELO name
postconf myhostname smtp_helo_name
```

**[RELAYHOST]** → verify you accept your own clients (simulate a client):

```bash
swaks --to test@example.com --from app@yourdomain.com \
      --server localhost:587 --tls --auth LOGin --auth-user 'relayuser' --auth-password 'xxxx'
# Or from an actual client box to test mynetworks-based relay (no auth):
swaks --to test@example.com --server relay.internal.example:25
```

---

## 5. Decoding errors — who owns the failure

| Symptom (and where you see it) | Hop at fault | Cause / fix |
|---|---|---|
| `Connection timed out` to relayhost in **client** log | Network / **[RELAYHOST]** | Firewall between client and relay, relay down, wrong port |
| `554 Relay access denied` from relayhost, in **client** log | **[RELAYHOST]** | Client IP not in `mynetworks` and not authenticating; check `smtpd_relay_restrictions` |
| `535 SASL authentication failed` in **client** log | **[CLIENT]** creds or **[RELAYHOST]** auth backend | Rotated password not updated in `sasl_passwd` + `postmap`; or relayhost's SASL (dovecot/cyrus) service down |
| `certificate verification failed` in **client** log | **[RELAYHOST]** cert or **[CLIENT]** CA bundle | Renew relay cert / fix hostname mismatch; update client CAfile |
| User's app gets immediate `Relay access denied` from the **client's** own Postfix | **[CLIENT]** | App not in client's `mynetworks` / not using localhost; check client `smtpd_relay_restrictions` |
| `Connection timed out` to internet MX in **relayhost** log | **[RELAYHOST]** egress | Outbound port 25 blocked (very common on cloud VMs), DNS failure |
| `550 5.7.1 ... SPF fail` from remote MX in **relayhost** log | DNS / **[RELAYHOST]** | Sending domain's SPF must include the relayhost's egress IP |
| `550 ... blocked using zen.spamhaus.org` in **relayhost** log | **[RELAYHOST]** reputation | Egress IP listed on an RBL — check for compromised client flooding spam (§7), request delisting |
| `450 greylisted` / `421 too many connections` in **relayhost** log | Remote throttling | Normal retries usually resolve; tune concurrency (§6) |
| `552 message size exceeds limit` at the relayhost | **[RELAYHOST]** config | Relayhost `message_size_limit` smaller than clients'; align them |
| `mail loops back to myself` in **relayhost** log | **[RELAYHOST]** | Domain listed in client's relayhost path but relayhost doesn't claim it in `mydestination`/`relay_domains` |
| Client shows `250 queued as X`, user says mail never arrived | **[RELAYHOST]** or beyond | Trace X on the relayhost; if relayhost also shows `250` from remote MX, it's spam-foldering/DMARC on the recipient side |
| Client log shows `relay=some-remote-mx[..]:25` instead of your relay, often with timeouts | **[CLIENT]** transport file | Domain not in transport map and no `*` catch-all → client tried direct-to-MX; add the domain or the catch-all, `postmap`, reload |
| Mail to `sub.example.com` bypasses the relay while `example.com` works | **[CLIENT]** transport file | `example.com` entry doesn't match subdomains; add a `.example.com` line |
| Transport edits "not taking effect" | **[EITHER]** | `postmap` not re-run — `.db` file is stale; also `postfix reload`, then `postsuper -r ALL` to reroute already-queued mail |
| `status=deferred (unknown mail transport error)` or `mail transport unavailable` | **[EITHER]** | Typo in the transport name column (e.g. `stmp:` for `smtp:`), or the named transport isn't defined in `master.cf` |

**Reading `delays=a/b/c/d`** (in `status=sent/deferred` lines): a = queued before qmgr, b = qmgr, c = connection setup (DNS+TCP+TLS+HELO), d = transmission. Big `c` on a client = relayhost slow to accept connections (check relayhost load, `anvil` limits, SASL backend latency). Big `c` on the relayhost = internet-side DNS/TLS slowness.

---

## 6. Relayhost throughput & backlog

**[RELAYHOST]** — when remote providers throttle you:

```bash
qshape deferred | head -20      # which destinations are backing up
```

```
smtp_destination_concurrency_limit = 5
smtp_destination_rate_delay = 1s
default_destination_recipient_limit = 50
minimal_backoff_time = 300s
maximal_backoff_time = 4000s
maximal_queue_lifetime = 5d
```

**[RELAYHOST]** — when your own clients overwhelm you:

```bash
grep anvil /var/log/mail.log | tail          # connection-rate limit hits
postconf smtpd_client_connection_count_limit smtpd_client_connection_rate_limit
```

Raise `default_process_limit` / smtpd process count in `master.cf` if clients queue up just trying to connect.

---

## 7. Log analysis one-liners

**[EITHER]**:

```bash
# Delivery status breakdown
grep 'status=' /var/log/mail.log | grep -oP 'status=\w+' | sort | uniq -c

# Top deferral reasons
grep 'status=deferred' /var/log/mail.log | grep -oP '\(.*\)' | sort | uniq -c | sort -rn | head

# pflogsumm daily overview (best single report)
pflogsumm -d today /var/log/mail.log
```

**[RELAYHOST]** — spot a compromised client or app:

```bash
# Which client IP is injecting the most mail?
grep 'postfix/smtpd' /var/log/mail.log | grep -oP 'client=\S+' | sort | uniq -c | sort -rn | head

# Top senders through the relay
grep 'from=<' /var/log/mail.log | grep -oP 'from=<[^>]*>' | sort | uniq -c | sort -rn | head

# Auth brute-force attempts against you
grep 'authentication failed' /var/log/mail.log | awk '{print $NF}' | sort | uniq -c | sort -rn | head
```

Outbound spike + RBL listing + spammy `550`s from remote MXes = one of your clients is compromised. Identify it with the first one-liner, block it in `mynetworks` or firewall, clean the relay queue of its junk (`postqueue -p | grep ...` → `postsuper -d`), then request RBL delisting.

---

## 8. Standard incident runbooks

**"User X's mail is stuck" (most common ticket):**
1. **[CLIENT]** send the three canaries from the same box (§0: internal, external, failing domain) — the pass/fail matrix usually names the broken route before you read a single config.
2. **[CLIENT]** `grep` user's address in mail.log → get queue ID → check status; diff against your canary's log lines.
3. If `status=sent ... queued as Y` → **[RELAYHOST]** `grep Y /var/log/mail.log`.
4. Fix at whichever hop the trail stops; requeue there (`postsuper -r ALL` or `postqueue -i ID`).

**"New server can't send mail":**
1. **[CLIENT]** `postconf transport_maps` set? Transport file deployed **and** `postmap`-ed (`.db` present and fresh)? `postmap -q '*' hash:/etc/postfix/transport` returns the relay?
2. **[CLIENT]** `nc -vz` to the relay nexthop OK?
3. **[RELAYHOST]** is the new box's subnet in `mynetworks` (or does it have SASL creds)? `postfix reload` after adding.
4. **[CLIENT]** `swaks` test through the relay.

**"Mail to one specific domain fails / bypasses the relay" (transport-map special):**
1. **[CLIENT]** `postmap -q thatdomain.com hash:/etc/postfix/transport` — entry present? Subdomain covered (`.thatdomain.com`)? Catch-all present?
2. **[CLIENT]** check the log's `relay=` field for that message — is it your relay or a direct MX?
3. Fix the map, `postmap`, `postfix reload`, `postqueue -i ID` (or `postsuper -r ALL` to reroute everything queued).

**"Everyone's mail is delayed":**
1. **[RELAYHOST]** `mailq | tail -1` — big queue? → `qshape deferred` → one domain or all?
2. All domains → egress/DNS/RBL problem (§4 relayhost tests, check RBLs).
3. One domain → that provider is deferring; check exact response, wait or tune §6.

**"Mail was sent but never arrived, no bounce":**
1. Trace across both hops (§1). Both show `250`? Message left your control.
2. Collect the remote MX's `250` response + timestamps (UTC) → check recipient spam folder, DMARC aggregate reports, or open a ticket with the recipient's provider.

---

## Quick reference card

| Task | Command | Where |
|---|---|---|
| Canary tests (internal + external + failing domain) | `echo body \| mail -s "canary" addr` ×3 | CLIENT |
| Show queue | `postqueue -p` / `mailq` | EITHER |
| Queue by domain | `qshape deferred` | EITHER |
| Flush / retry one | `postqueue -f` / `postqueue -i ID` | EITHER |
| Delete / requeue all | `postsuper -d ID` / `postsuper -r ALL` | EITHER |
| View queued message | `postcat -q ID` | EITHER |
| Effective config | `postconf -n` | EITHER |
| Validate + reload | `postfix check && systemctl reload postfix` | EITHER |
| Query route for a domain | `postmap -q domain.com hash:/etc/postfix/transport` | EITHER |
| Check catch-all route | `postmap -q '*' hash:/etc/postfix/transport` | CLIENT |
| Rebuild transport map | `postmap /etc/postfix/transport && postfix reload` | EITHER |
| Rebuild/query SASL map | `postmap /etc/postfix/sasl_passwd` / `postmap -q "key" hash:...` | CLIENT |
| Test TLS to relay | `openssl s_client -connect relay:587 -starttls smtp` | CLIENT |
| End-to-end test via relay | `swaks --server relay:587 --tls --auth ...` | CLIENT |
| Check client allowlist | `postconf mynetworks smtpd_relay_restrictions` | RELAYHOST |
| Check egress + PTR | `nc -vz mx 25` / `dig -x EGRESS_IP` | RELAYHOST |
| Find noisy client | `grep smtpd mail.log \| grep -oP 'client=\S+' \| sort \| uniq -c \| sort -rn` | RELAYHOST |
| Daily summary | `pflogsumm -d today /var/log/mail.log` | EITHER |
