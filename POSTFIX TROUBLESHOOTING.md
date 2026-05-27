# Postfix Troubleshooting Guide

A practical playbook with real outputs, what’s normal vs. what’s a smoking gun, and how to interpret every log line. Work through these steps top to bottom; each builds on what the previous one tells you.

## Table of Contents

1. [Is Postfix even running?](#step-1-is-postfix-even-running)
1. [Look at the queue](#step-2-look-at-the-queue)
1. [Read the maillog](#step-3-read-the-maillog)
1. [Decode SMTP status codes and DSN](#step-4-decode-smtp-status-codes-and-dsn)
1. [Trace a specific message](#step-4-trace-a-specific-message)
1. [Diagnose by queue type with qshape](#step-6-diagnose-by-queue-type-with-qshape)
1. [Check configuration](#step-7-check-configuration)
1. [DNS, MX, and connectivity](#step-8-dns-mx-and-connectivity)
1. [TLS and authentication](#step-9-tls-and-authentication)
1. [Reputation: SPF, DKIM, DMARC, blocklists](#step-10-reputation-spf-dkim-dmarc-blocklists)
1. [Resource and rate-limit issues](#step-11-resource-and-rate-limit-issues)
1. [Live SMTP conversation testing](#step-12-live-smtp-conversation-testing)
1. [Quick triage flow](#quick-triage-flow)
1. [One-liner cheat sheet](#one-liner-cheat-sheet)

-----

## Step 1: Is Postfix even running?

Before debugging delivery, confirm the service is actually up.

```bash
sudo systemctl status postfix
```

**Healthy output:**

```
● postfix.service - Postfix Mail Transport Agent
     Loaded: loaded (/lib/systemd/system/postfix.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-05-26 09:14:22 UTC; 2 days ago
       Docs: man:postfix(1)
   Main PID: 1842 (master)
      Tasks: 6 (limit: 38420)
     Memory: 14.2M
     CGroup: /system.slice/postfix.service
             ├─1842 /usr/lib/postfix/sbin/master -w
             ├─1843 pickup -l -t unix -u -c
             ├─1844 qmgr -l -t unix -u
             └─8420 tlsmgr -l -t unix -u -c
```

The `master` process is the supervisor. If you see only `master` and no children, the daemons aren’t being spawned (broken `master.cf`). If you see `master` is dead, Postfix is fully down.

**Broken output:**

```
● postfix.service - Postfix Mail Transport Agent
     Loaded: loaded (/lib/systemd/system/postfix.service; enabled; vendor preset: enabled)
     Active: failed (Result: exit-code) since Tue 2026-05-26 14:20:18 UTC; 4min ago
   Main PID: 18420 (code=exited, status=1/FAILURE)

May 26 14:20:18 mailhost postfix/postfix-script[18419]: fatal: parameter inet_interfaces: no local interface found for ::1
```

The systemd log lines at the bottom usually tell you exactly what’s wrong — here, IPv6 listening is configured but the host has no IPv6.

**Verify the listening processes:**

```bash
sudo ss -tlnp | grep -E ':25|:587|:465'
```

```
LISTEN 0  100  0.0.0.0:25    0.0.0.0:*  users:(("master",pid=1842,fd=13))
LISTEN 0  100  0.0.0.0:587   0.0.0.0:*  users:(("master",pid=1842,fd=17))
LISTEN 0  100     [::]:25       [::]:*  users:(("master",pid=1842,fd=14))
```

If port 25 isn’t listening, Postfix isn’t accepting mail. If only `127.0.0.1:25` is shown, `inet_interfaces` is set to `localhost` — outside hosts can’t connect.

**Check what Postfix thinks of itself:**

```bash
sudo postfix status
```

```
postfix/postfix-script: the Postfix mail system is running: PID: 1842
```

Or, if not:

```
postfix/postfix-script: the Postfix mail system is not running
```

## Step 2: Look at the queue

The queue is where you find evidence. If mail is “stuck,” it lives here.

```bash
mailq
# or equivalently
postqueue -p
```

**Empty queue (mail is flowing):**

```
Mail queue is empty
```

**Queue with stuck mail:**

```
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
2FC8824D24*    10588 Thu May 26 14:52:41  sender@example.com
                                          (connect to mail.dest.com[203.0.113.42]:25: Connection timed out)
                                          recipient@dest.com

A4B91827FE     14820 Thu May 26 14:48:12  sender@example.com
                                          (host gmail-smtp-in.l.google.com[142.250.80.27] said: 421-4.7.0
                                          [203.0.113.5      15] Our system has detected an unusual rate of unsolicited mail (in
                                          reply to MAIL FROM command))
                                          someone@gmail.com

!8420A91DF2     8204 Thu May 26 14:42:01  sender@example.com
                                          recipient@partner.com

-- 18 Kbytes in 3 Requests.
```

**How to read the queue listing:**

|Symbol after Queue ID|Meaning                                                          |
|---------------------|-----------------------------------------------------------------|
|(nothing)            |In the `deferred` queue — temporary failure, will retry          |
|`*`                  |In the `active` queue — being processed right now                |
|`!`                  |On `hold` — manually frozen, will not be delivered until released|

**Key fields:**

- **Queue ID** (e.g., `2FC8824D24`) — unique identifier; use this to grep logs and run `postcat`
- **Size** — message size in bytes
- **Arrival Time** — when Postfix accepted the message; large gap from current time = stuck for that long
- **Sender** — envelope sender (return-path), not necessarily the `From:` header
- **Parenthesized line** — the reason for deferral, straight from the remote server or the local error daemon
- **Recipient(s)** — envelope recipients

The parenthesized reason is the single most important field. It’s the remote server (or local subsystem) telling you exactly why the message hasn’t moved.

**Queue size at a glance:**

```bash
sudo postqueue -p | tail -1
```

```
-- 18 Kbytes in 3 Requests.
```

**Count by queue directory** (faster on huge queues than `mailq`):

```bash
sudo find /var/spool/postfix/{active,deferred,incoming,hold,corrupt} -type f 2>/dev/null | \
  awk -F/ '{print $5}' | sort | uniq -c
```

```
      2 active
   4820 deferred
      0 incoming
      8 hold
```

### Understanding the queue directories

Postfix has multiple queues, each with a purpose. They live under `/var/spool/postfix/`.

|Queue                     |Purpose                                                                              |What it tells you when full                                                  |
|--------------------------|-------------------------------------------------------------------------------------|-----------------------------------------------------------------------------|
|`incoming`                |Newly-received mail not yet handed off to the queue manager.                         |Should be near-empty. Backlog = `cleanup` slow or `qmgr` not running.        |
|`active`                  |Messages the queue manager is currently delivering. Bounded in size (default ~20000).|Always small. If full, the queue manager can’t push messages out fast enough.|
|`deferred`                |Messages that failed delivery and will be retried later.                             |The usual “stuck mail” queue. Most diagnostics live here.                    |
|`hold`                    |Messages frozen by an admin (`postsuper -h`) — never delivered until released.       |Should normally be empty. Non-zero = someone manually held messages.         |
|`corrupt`                 |Messages with damaged queue files.                                                   |Should always be empty. Non-zero = filesystem corruption or postfix bug.     |
|`bounce`, `defer`, `trace`|Per-message status logs used by `bounce`, `defer`, and `trace` daemons.              |Internal. Rarely need to look here.                                          |

## Step 3: Read the maillog

Almost every Postfix diagnostic step ends in the maillog.

**Log location varies by distribution:**

- Debian/Ubuntu: `/var/log/mail.log`
- RHEL/CentOS/Rocky/Fedora: `/var/log/maillog`
- Systemd journal (any modern distro): `journalctl -u postfix`

```bash
sudo tail -100 /var/log/maillog
# or
sudo journalctl -u postfix --since "30 minutes ago"
```

**A successful delivery, full trace:**

```
May 26 14:52:41 mailhost postfix/smtpd[14820]: connect from client.example.com[198.51.100.42]
May 26 14:52:41 mailhost postfix/smtpd[14820]: 2FC8824D24: client=client.example.com[198.51.100.42]
May 26 14:52:41 mailhost postfix/cleanup[14821]: 2FC8824D24: message-id=<20260526145241.ABC@client.example.com>
May 26 14:52:41 mailhost postfix/qmgr[1844]: 2FC8824D24: from=<sender@example.com>, size=10588, nrcpt=1 (queue active)
May 26 14:52:42 mailhost postfix/smtp[14822]: 2FC8824D24: to=<recipient@dest.com>, relay=mail.dest.com[203.0.113.42]:25, delay=1.2, delays=0.1/0/0.8/0.3, dsn=2.0.0, status=sent (250 2.0.0 OK 1716736362 abc123 - gsmtp)
May 26 14:52:42 mailhost postfix/qmgr[1844]: 2FC8824D24: removed
```

Read this top-to-bottom — it’s the life of a message:

1. `smtpd connect from` — TCP connection accepted
1. `smtpd: <queue_id>: client=` — message assigned a queue ID
1. `cleanup: <queue_id>: message-id=` — RFC 822 message-id extracted
1. `qmgr: <queue_id>: from=<>, size=, nrcpt=` — message in the active queue
1. `smtp: <queue_id>: to=<>, relay=, delay=, dsn=, status=sent` — actually delivered
1. `qmgr: <queue_id>: removed` — gone from the queue

If you see steps 1-4 but no step 5, the message is stuck in the queue. If you see step 5 but `status=deferred` or `bounced` instead of `sent`, you have a delivery problem.

**Key fields in the delivery line:**

|Field             |Meaning                                                                                                                           |
|------------------|----------------------------------------------------------------------------------------------------------------------------------|
|`to=`             |Envelope recipient                                                                                                                |
|`relay=`          |Where Postfix tried to deliver. `none` means it never connected. `local` = local delivery. Hostname[IP]:port = remote SMTP server.|
|`delay=`          |Total time from queue acceptance to delivery attempt, in seconds. Large values = stuck in queue.                                  |
|`delays=`         |Four-part breakdown: `before-queue / qmgr / connection-setup / transmission`. Lets you see which phase was slow.                  |
|`dsn=`            |Delivery Status Notification code (RFC 3463). 2.x.x = success, 4.x.x = temporary failure, 5.x.x = permanent failure.              |
|`status=`         |One of `sent`, `deferred`, `bounced`, `expired`, `undeliverable`.                                                                 |
|Parenthesized text|The actual SMTP response from the remote server.                                                                                  |

**A deferred delivery (temporary failure):**

```
May 26 14:48:12 mailhost postfix/smtp[14830]: A4B91827FE: to=<someone@gmail.com>, relay=gmail-smtp-in.l.google.com[142.250.80.27]:25, delay=302, delays=0.05/0/300/2, dsn=4.7.0, status=deferred (host gmail-smtp-in.l.google.com[142.250.80.27] said: 421-4.7.0 [203.0.113.15] Our system has detected an unusual rate of unsolicited mail (in reply to end of DATA command))
```

Reading this: connection succeeded (notice `delays=` shows 300s in connection — but that’s because the remote was slow, not a timeout), the recipient was a Gmail address, and Gmail returned `421-4.7.0` flagging us as a likely spam source. This is a reputation problem, not a config problem.

**A bounced delivery (permanent failure):**

```
May 26 14:42:01 mailhost postfix/smtp[14842]: 8420A91DF2: to=<missing@example.com>, relay=mail.example.com[203.0.113.99]:25, delay=2, delays=0.1/0/1.4/0.5, dsn=5.1.1, status=bounced (host mail.example.com[203.0.113.99] said: 550 5.1.1 <missing@example.com>: Recipient address rejected: User unknown in virtual mailbox table (in reply to RCPT TO command))
```

`5.1.1` = “mailbox does not exist.” This is a permanent failure; Postfix will not retry, and a bounce will be sent to the original sender.

**A local rejection (Postfix refused to accept the mail):**

```
May 26 14:30:18 mailhost postfix/smtpd[14820]: NOQUEUE: reject: RCPT from client.example.com[198.51.100.99]: 554 5.7.1 <baduser@us.example.com>: Relay access denied; from=<spammer@elsewhere.net> to=<baduser@us.example.com> proto=ESMTP helo=<client.example.com>
```

`NOQUEUE` = the message never got a queue ID because we rejected it before accepting. `reject` followed by the rule that triggered. `Relay access denied` = the client isn’t allowed to relay through us.

**Errors worth searching for:**

```bash
sudo grep -E 'postfix.*(panic|fatal|error|warning|reject)' /var/log/maillog | tail -20
sudo grep -E 'postfix/qmgr.*(panic|fatal|error|warning)' /var/log/maillog | tail -20
```

`qmgr` warnings are particularly valuable — they’re often actionable, e.g., “all network protocols disabled” or “premature end-of-input.”

## Step 4: Decode SMTP status codes and DSN

Almost every delivery problem shows up as a status code. Knowing these by sight makes log reading instant.

### SMTP reply codes (the 3-digit number)

|Range|Class            |Behavior                                                                       |
|-----|-----------------|-------------------------------------------------------------------------------|
|`2xx`|Success          |Message accepted (e.g., `250 OK`).                                             |
|`3xx`|Intermediate     |Server is waiting for more input (e.g., `354 End data with <CR><LF>.<CR><LF>`).|
|`4xx`|Transient failure|Postfix retries. Will eventually expire as bounce if not resolved.             |
|`5xx`|Permanent failure|Postfix bounces immediately.                                                   |

### Enhanced status codes (DSN, the `x.y.z` number — RFC 3463)

The DSN code has three parts: `class.subject.detail`.

**Class (first digit):**

- `2` — success
- `4` — persistent transient failure (deferred)
- `5` — permanent failure (bounced)

**Subject (second digit):** what the failure is about.

|Subject|Meaning                                                           |
|-------|------------------------------------------------------------------|
|`0`    |Other / undefined                                                 |
|`1`    |Addressing — bad mailbox, bad sender, bad recipient               |
|`2`    |Mailbox — full, disabled, not accepting                           |
|`3`    |Mail system — full disk, out of resources                         |
|`4`    |Network / routing — DNS, no MX, connection failed                 |
|`5`    |Mail protocol — bad SMTP syntax, version mismatch                 |
|`6`    |Message content — bad MIME, encoding, conversion failure          |
|`7`    |Security / policy — relay denied, blocked by policy, spam rejected|

### Common codes you’ll see and what they really mean

|Code    |What the log says                            |What it actually means                                      |Where to look next                               |
|--------|---------------------------------------------|------------------------------------------------------------|-------------------------------------------------|
|`4.4.1` |`Connection timed out`                       |Remote SMTP server unreachable on port 25                   |Firewall, ISP port 25 block, remote down (Step 8)|
|`4.4.2` |`Connection lost`                            |TCP reset mid-conversation                                  |MTU issues, intermediate firewall, remote crashed|
|`4.7.0` |`Try again later` (often greylisting)        |Receiving server temporarily rejecting; will accept on retry|Wait. Normal.                                    |
|`4.7.1` |`Client host blocked`                        |Reputation-based deferral, soft blocklist hit               |Step 10 (reputation)                             |
|`5.1.1` |`User unknown` / `Recipient address rejected`|Mailbox doesn’t exist on remote side                        |Confirm address spelling                         |
|`5.1.2` |`Bad destination host`                       |Domain doesn’t resolve                                      |DNS / MX (Step 8)                                |
|`5.1.8` |`Bad sender address syntax`                  |Envelope sender malformed                                   |Fix the originating application                  |
|`5.2.2` |`Mailbox full`                               |Recipient over quota                                        |Recipient must clean up                          |
|`5.4.4` |`No route to host`                           |No MX, no A fallback                                        |Step 8                                           |
|`5.7.0` |`Message rejected` (catch-all policy)        |Some content/policy rejected the message                    |Bounce text usually has detail                   |
|`5.7.1` |`Relay access denied` / `Sender blocked`     |Either we won’t relay for them, or they won’t accept from us|Step 7 (config) or Step 10 (reputation)          |
|`5.7.25`|`Reverse DNS does not match`                 |PTR record missing/wrong                                    |Set PTR for sending IP                           |
|`5.7.26`|`SPF/DKIM alignment failed`                  |DMARC failure                                               |Step 10                                          |

**Common Postfix-side errors (not from remote):**

|Log text                                                          |Meaning                                                                   |
|------------------------------------------------------------------|--------------------------------------------------------------------------|
|`Name service error for name=X type=MX: Host not found, try again`|DNS lookup failed (Step 8)                                                |
|`mail transport unavailable`                                      |The transport named in `master.cf` isn’t running or isn’t reachable       |
|`Host or domain name not found`                                   |Domain has no MX and no A record                                          |
|`lost connection with X while sending end of data`                |Remote dropped us mid-message — often anti-spam scanners                  |
|`delivery temporarily suspended`                                  |Postfix has temporarily backed off after many failures to this destination|
|`Permission denied` on a queue file                               |Filesystem permission issue under `/var/spool/postfix/`                   |

## Step 5: Trace a specific message

Once you have a queue ID, you can follow it everywhere.

**Find every log line for a message:**

```bash
sudo grep '2FC8824D24' /var/log/maillog
```

Or across rotated logs:

```bash
sudo zgrep '2FC8824D24' /var/log/maillog*
```

**Read the actual queue file** (headers, body, envelope, all decoded):

```bash
sudo postcat -vq 2FC8824D24
```

**Output:**

```
*** ENVELOPE RECORDS deferred/2/2FC8824D24 ***
message_size:           10588             254               1               0           10588
message_arrival_time: Thu May 26 14:52:41 2026
create_time: Thu May 26 14:52:41 2026
named_attribute: rewrite_context=local
sender_fullname: Web App
sender: sender@example.com
named_attribute: log_client_name=client.example.com
named_attribute: log_client_address=198.51.100.42
named_attribute: log_message_origin=client.example.com[198.51.100.42]
named_attribute: log_helo_name=client.example.com
named_attribute: log_protocol_name=ESMTP
named_attribute: client_name=client.example.com
named_attribute: reverse_client_name=client.example.com
named_attribute: client_address=198.51.100.42
named_attribute: helo_name=client.example.com
named_attribute: client_protocol=ESMTP
named_attribute: encryption_protocol=TLSv1.3
named_attribute: encryption_cipher=TLS_AES_256_GCM_SHA384
named_attribute: encryption_keysize=256
original_recipient: recipient@dest.com
recipient: recipient@dest.com
*** MESSAGE CONTENTS deferred/2/2FC8824D24 ***
Received: from client.example.com (client.example.com [198.51.100.42])
    by mailhost.example.com (Postfix) with ESMTPS id 2FC8824D24
    for <recipient@dest.com>; Thu, 26 May 2026 14:52:41 +0000 (UTC)
From: Web App <sender@example.com>
To: recipient@dest.com
Subject: Your account update
Date: Thu, 26 May 2026 14:52:41 +0000
Message-Id: <20260526145241.ABC@client.example.com>

Hello, your account has been updated.
*** HEADER EXTRACTED deferred/2/2FC8824D24 ***
*** MESSAGE FILE END deferred/2/2FC8824D24 ***
```

This is gold. You see:

- Where the message came from (client name, IP, HELO, TLS info)
- The actual envelope sender and recipient (which may differ from `From:` / `To:` headers)
- The full message content
- Which queue directory it lives in

**Force immediate delivery attempt** (don’t wait for the next retry):

```bash
sudo postqueue -i 2FC8824D24
```

**Force the entire queue to retry:**

```bash
sudo postqueue -f
```

**Delete a specific message:**

```bash
sudo postsuper -d 2FC8824D24
```

**Hold a message** (stop trying to deliver until manually released):

```bash
sudo postsuper -h 2FC8824D24
sudo postsuper -H 2FC8824D24    # release
```

**Mass operations:**

```bash
sudo postsuper -d ALL deferred              # delete all deferred messages (careful!)
sudo postsuper -d ALL                       # nuke the entire queue (very careful!)
sudo postsuper -r ALL                       # requeue everything (re-runs cleanup, useful after config change)
```

**Delete by pattern** (e.g., all messages from a specific sender):

```bash
sudo mailq | awk '/^[A-F0-9]+/ {qid=$1} /sender@example.com/ {print qid}' | sudo postsuper -d -
```

## Step 6: Diagnose by queue type with qshape

`qshape` shows the **age distribution** of messages by destination domain. It’s the single best tool for spotting patterns in a clogged queue.

```bash
sudo qshape deferred | head -20
```

**Output:**

```
                         T  5 10 20 40 80 160 320 640 1280 1280+
                  TOTAL 482  4  8 14 28 42  84 102  98   72    30
                gmail.com 380  2  4 10 22 38  72  88  82   52    10
              outlook.com  68  1  2  3  4  2   8   10   8    20    10
                 yahoo.com  18  0  1  1  2  2   2    4    6     0     0
                other.com  16  1  1  0  0  0   2    0    2     0    10
```

**How to read the columns:**

|Column |Meaning                                     |
|-------|--------------------------------------------|
|`T`    |Total messages for this domain              |
|`5`    |Messages that arrived in the last 5 minutes |
|`10`   |Messages 5-10 minutes old                   |
|`20`   |Messages 10-20 minutes old                  |
|`40`   |Messages 20-40 minutes old                  |
|`80`   |Messages 40-80 minutes old                  |
|`160`  |Messages 80-160 minutes old (~2.5 hours)    |
|`320`  |Messages 160-320 minutes (~5 hours)         |
|`640`  |Messages 320-640 minutes (~10 hours)        |
|`1280` |Messages 640-1280 minutes (~21 hours)       |
|`1280+`|Messages older than 1280 minutes (>21 hours)|

**Patterns to spot instantly:**

**One domain dominates the queue** — like the example above where gmail.com has 380 of 482 messages. The problem is specific to that destination. Common causes: greylisting, reputation (Step 10), rate limit at that domain.

**Spread evenly across many domains, all young (left-heavy):**

```
                  TOTAL 4820 4820  0  0  0  0  0  0  0  0  0
```

A sudden burst of new mail. Either legitimate volume spike, or you just got compromised and an account is mass-sending. Check `sudo postqueue -p | grep -c "^[A-F0-9]" | head -1` over time to see growth rate.

**Spread evenly across many domains, all old (right-heavy):**

```
                  TOTAL 1820  0  0  0  0  0  0  0  240  680  900
```

Your server has a generic outbound problem — probably no internet, DNS broken, or port 25 blocked. Step 8.

**Active queue piling up:**

```bash
sudo qshape active
```

The active queue is supposed to be near-empty (messages flow through in seconds). A backlog here means the queue manager can’t push messages to delivery agents fast enough — usually because all delivery agents are blocked waiting on slow destinations. Tune `default_destination_concurrency_limit` or `smtp_destination_concurrency_limit`.

**Incoming queue piling up:**

```bash
sudo qshape incoming
```

Also supposed to be near-empty. Backlog = `cleanup` daemon slow, or `qmgr` not running. Check `systemctl status postfix` and Step 1.

## Step 7: Check configuration

When Postfix is misbehaving in confusing ways, the config is often the answer.

**Show only non-default settings** (what someone has customized):

```bash
sudo postconf -n
```

**Typical output worth inspecting:**

```
alias_database = hash:/etc/aliases
alias_maps = hash:/etc/aliases
inet_interfaces = all
inet_protocols = ipv4
mydestination = mailhost.example.com, localhost.localdomain, localhost
mydomain = example.com
myhostname = mailhost.example.com
mynetworks = 127.0.0.0/8 10.0.0.0/8
myorigin = $mydomain
relayhost = [smtp.relay.example.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtpd_tls_cert_file = /etc/postfix/tls/cert.pem
smtpd_tls_key_file = /etc/postfix/tls/key.pem
smtpd_tls_security_level = may
```

**The fields worth scanning every time:**

|Setting                   |What to check                                                                                                                                                                       |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`myhostname`              |Should be the FQDN you use in EHLO/HELO. Must match PTR record.                                                                                                                     |
|`mydomain`                |Your primary domain. Used as default in `myorigin`.                                                                                                                                 |
|`myorigin`                |What domain unqualified addresses get rewritten to. Wrong value = mail appears to come from wrong domain.                                                                           |
|`mydestination`           |Domains this server considers “local” — mail for these is delivered locally. If your domain is here but shouldn’t be (you’re a relay, not the final destination), mail bounces back.|
|`mynetworks`              |IP ranges allowed to relay through this server. **Too broad = open relay.** Should usually be `127.0.0.0/8` plus your specific internal nets.                                       |
|`inet_interfaces`         |Network interfaces to listen on. `all` = listen everywhere. `localhost` = only local. `loopback-only` = won’t accept external mail.                                                 |
|`inet_protocols`          |`ipv4`, `ipv6`, or `all`. If host has no IPv6 but this is `all`, Postfix will try IPv6 and fail.                                                                                    |
|`relayhost`               |If set, all outbound mail goes through this host. Empty = direct-to-MX.                                                                                                             |
|`smtp_sasl_*`             |SASL auth for the relayhost.                                                                                                                                                        |
|`smtp_tls_security_level` |`none`, `may`, `encrypt`, `dane`, `verify`, `secure`.                                                                                                                               |
|`smtpd_tls_security_level`|Same options, for inbound.                                                                                                                                                          |

**Check syntax of all config files:**

```bash
sudo postfix check
```

Returns nothing if all is well. Any output is an error to fix.

**Show a specific parameter’s value:**

```bash
sudo postconf message_size_limit
sudo postconf mailbox_size_limit
sudo postconf default_destination_concurrency_limit
```

**Show default vs configured value side by side:**

```bash
diff <(sudo postconf -d | sort) <(sudo postconf | sort) | head -40
```

**Reload after changing main.cf** (doesn’t drop connections):

```bash
sudo postfix reload
```

**View master.cf** (which services run, and how):

```bash
sudo postconf -M
```

```
smtp       inet  n       -       y       -       -       smtpd
pickup     unix  n       -       y       60      1       pickup
cleanup    unix  n       -       y       -       0       cleanup
qmgr       unix  n       -       n       300     1       qmgr
tlsmgr     unix  -       -       y       1000?   1       tlsmgr
rewrite    unix  -       -       y       -       -       trivial-rewrite
bounce     unix  -       -       y       -       0       bounce
defer      unix  -       -       y       -       0       bounce
trace      unix  -       -       y       -       0       bounce
smtp       unix  -       -       y       -       -       smtp
local      unix  -       n       n       -       -       local
virtual    unix  -       n       n       -       -       virtual
lmtp       unix  -       -       y       -       -       lmtp
```

The `smtp inet ... smtpd` line at the top is the SMTP listener on port 25. If you don’t see it, Postfix isn’t accepting external mail.

## Step 8: DNS, MX, and connectivity

A huge chunk of Postfix problems are actually DNS or network problems wearing a Postfix mask.

**MX lookup for the destination:**

```bash
dig +short MX gmail.com
```

```
10 smtp.google.com.
```

If `dig` returns nothing or `SERVFAIL`, your DNS is broken (or the destination has no MX). When there’s no MX, Postfix falls back to the A record per RFC 5321 — verify that exists:

```bash
dig +short A example.com
```

**Reverse DNS for your sending IP** (critical for outbound deliverability):

```bash
dig +short -x 203.0.113.15
```

```
mailhost.example.com.
```

The PTR record **must** point to a hostname that, when looked up forward, resolves back to the same IP. Mismatched FCrDNS (Forward-Confirmed reverse DNS) is one of the most common reasons big providers defer or block.

**Verify your forward record matches:**

```bash
dig +short A mailhost.example.com
```

Should return `203.0.113.15`. If it doesn’t, you have an FCrDNS mismatch.

**Test port 25 connectivity to the destination:**

```bash
nc -zv smtp.google.com 25
```

```
Connection to smtp.google.com (142.250.80.27) 25 port [tcp/smtp] succeeded!
```

**If port 25 is blocked outbound** (very common on residential and cloud providers):

```
nc: connect to smtp.google.com port 25 (tcp) failed: Connection timed out
```

Many ISPs and cloud providers (AWS, GCP, Azure) block outbound port 25 by default. You need to either request unblock from the provider or use a relayhost on port 587/465.

**Test from another machine to your server:**

```bash
nc -zv mailhost.example.com 25
```

**Check whether DNS is working at all from Postfix’s perspective:**

```bash
sudo -u postfix dig +short MX gmail.com
```

If this fails but a regular `dig` works, Postfix is running chrooted (under `/var/spool/postfix/`) and the chroot doesn’t have working DNS — you need to copy `/etc/resolv.conf` and friends in, or disable chroot in `master.cf`.

**Postfix DNS debug:**

```bash
sudo postconf smtp_dns_support_level
sudo postconf smtp_host_lookup
```

Default `smtp_host_lookup = dns` is usually right. If set to `native`, Postfix uses the system resolver and you should debug with `getent hosts <host>` instead.

## Step 9: TLS and authentication

TLS failures often look like cryptic “lost connection” errors. SASL failures look like authentication-denied messages.

**Common TLS log lines, healthy:**

```
postfix/smtp[14820]: Trusted TLS connection established to smtp.google.com[142.250.80.27]:25: TLSv1.3 with cipher TLS_AES_256_GCM_SHA384 (256/256 bits) key-exchange X25519 server-signature ECDSA (P-256) server-digest SHA256
```

`Trusted` means cert chain validated. `Untrusted` means the cert didn’t validate (self-signed or wrong CA) but the connection still happened (opportunistic TLS).

**TLS failure:**

```
postfix/smtp[14820]: SSL_connect error to smtp.partner.com[203.0.113.42]:25: -1
postfix/smtp[14820]: warning: TLS library problem: error:14094410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure
```

This is the remote side rejecting our TLS handshake — usually because our cipher list is too restrictive or too permissive for them. Check:

```bash
sudo postconf | grep -E 'smtp_tls_(protocols|ciphers|mandatory)'
```

**Test TLS to a remote server manually:**

```bash
openssl s_client -connect smtp.google.com:25 -starttls smtp -crlf
```

This shows you the cert, the cipher, and lets you proceed with SMTP commands manually.

**SASL authentication problems** (when sending through a relayhost):

```
postfix/smtp[14820]: SASL authentication failed; cannot authenticate to server smtp.relay.example.com[203.0.113.20]: no mechanism available
postfix/smtp[14820]: warning: SASL authentication failure: No worthy mechs found
```

The relay offered no auth mechanisms our client can use. Usually means:

- Missing `libsasl2-modules` package on Debian/Ubuntu (`apt install libsasl2-modules`)
- Missing `cyrus-sasl-plain` on RHEL (`yum install cyrus-sasl-plain`)
- `smtp_sasl_security_options` excludes the only mechs the server offers

**Check the SASL password map:**

```bash
sudo cat /etc/postfix/sasl_passwd
```

Should look like:

```
[smtp.relay.example.com]:587    username:password
```

After editing, you must rebuild the hash database:

```bash
sudo postmap /etc/postfix/sasl_passwd
sudo postfix reload
```

The brackets `[...]` are important — they tell Postfix not to do MX lookup on this name, treating it as the literal SMTP server.

## Step 10: Reputation: SPF, DKIM, DMARC, blocklists

When mail delivers successfully to some recipients but gets deferred/bounced at big providers, the problem is almost always reputation.

**Check SPF for your sending domain:**

```bash
dig +short TXT example.com | grep spf
```

```
"v=spf1 ip4:203.0.113.15 include:_spf.google.com -all"
```

The sending IP must be authorized either directly (`ip4:`) or via an include. `-all` is “hard fail” — receivers should reject mail not matching. `~all` is “soft fail” — receivers usually deliver to spam.

**Verify the sending IP is actually covered:**
The IP your mail leaves on must appear (transitively) in the SPF record. If you have multiple sending sources (your mail server, a SaaS, Google Workspace), all must be included.

**DKIM signing on outbound:**

```bash
sudo grep -E 'dkim' /var/log/maillog | tail -20
```

Look for log lines from your DKIM milter (`opendkim`, `rspamd`, etc.) signing outbound mail. A signed message will have a `DKIM-Signature:` header.

**DMARC policy:**

```bash
dig +short TXT _dmarc.example.com
```

```
"v=DMARC1; p=reject; rua=mailto:dmarc@example.com; aspf=s; adkim=s"
```

`p=reject` = receivers should reject mail that fails alignment. `p=quarantine` = spam folder. `p=none` = monitor only.

**Check your sending IP against major blocklists:**

```bash
for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
  result=$(dig +short ${IP_REVERSED}.${bl})
  if [ -n "$result" ]; then
    echo "LISTED on $bl: $result"
  else
    echo "clean on $bl"
  fi
done
```

Where `IP_REVERSED` is your IP with octets reversed (e.g., for `203.0.113.15`, use `15.113.0.203`).

A faster way: use a web service like [MXToolbox blacklist check](https://mxtoolbox.com/blacklists.aspx) or [multirbl.valli.org](https://multirbl.valli.org).

**Reputation-related log patterns:**

|Log fragment                                    |Meaning                                       |
|------------------------------------------------|----------------------------------------------|
|`421-4.7.0 ... unusual rate of unsolicited mail`|Gmail soft-blocking us as a likely spam source|
|`550 5.7.1 ... blocked using Spamhaus`          |Recipient using Spamhaus, our IP is listed    |
|`550 5.7.26 ... DMARC`                          |Our DMARC alignment failed                    |
|`550 5.7.25 ... PTR record`                     |Our reverse DNS is missing or doesn’t match   |
|`554 5.7.1 ... open relay`                      |They think we’re an open relay                |

## Step 11: Resource and rate-limit issues

Sometimes Postfix isn’t broken — it’s just choking on volume.

**Process count:**

```bash
ps aux | grep -E 'postfix|smtpd|smtp$' | grep -v grep | wc -l
```

**Open file descriptors:**

```bash
sudo lsof -u postfix | wc -l
```

**Postfix process limits:**

```bash
sudo postconf default_process_limit
sudo postconf smtpd_client_connection_count_limit
sudo postconf smtpd_client_connection_rate_limit
sudo postconf default_destination_concurrency_limit
sudo postconf default_destination_rate_delay
```

|Parameter                              |What it controls                                    |When to tune                                                              |
|---------------------------------------|----------------------------------------------------|--------------------------------------------------------------------------|
|`default_process_limit`                |Max simultaneous processes per service (default 100)|Increase for very high volume; decrease if running out of file descriptors|
|`smtpd_client_connection_count_limit`  |Max concurrent connections from one client IP       |Decrease to mitigate spam burst from one source                           |
|`smtpd_client_connection_rate_limit`   |Max connections per minute from one client IP       |Same — rate-limit abusive clients                                         |
|`default_destination_concurrency_limit`|Max parallel deliveries to one destination          |Decrease (e.g., 5) for destinations that rate-limit you                   |
|`default_destination_rate_delay`       |Minimum delay between deliveries to same destination|Increase (e.g., `1s`) to throttle outbound to one domain                  |

**Disk space** (queue partition):

```bash
df -h /var/spool/postfix
```

A full queue partition causes immediate failures. Symptoms: messages bounce with `4.3.0` or `5.3.5`, log shows `No space left on device`.

**Inode exhaustion** (rare but devastating with millions of small queue files):

```bash
df -i /var/spool/postfix
```

**Watch active connections in real time:**

```bash
sudo watch -n 1 "ss -tnp state established '( sport = :25 or sport = :587 or dport = :25 or dport = :587 )' | wc -l"
```

**Queue growth rate** (run twice 60 seconds apart):

```bash
date && sudo find /var/spool/postfix/deferred -type f | wc -l
sleep 60
date && sudo find /var/spool/postfix/deferred -type f | wc -l
```

Growing rapidly = something is wrong. Shrinking = queue is draining (good). Flat = steady state.

## Step 12: Live SMTP conversation testing

When all else fails, talk to Postfix yourself.

**Inbound test (verify Postfix accepts mail):**

```bash
telnet localhost 25
```

Or with TLS:

```bash
openssl s_client -connect localhost:25 -starttls smtp -crlf
```

**Then type the SMTP commands:**

```
220 mailhost.example.com ESMTP Postfix (Ubuntu)
EHLO test.example.com
250-mailhost.example.com
250-PIPELINING
250-SIZE 10240000
250-VRFY
250-ETRN
250-STARTTLS
250-ENHANCEDSTATUSCODES
250-8BITMIME
250-DSN
250 SMTPUTF8
MAIL FROM:<test@example.com>
250 2.1.0 Ok
RCPT TO:<recipient@example.com>
250 2.1.5 Ok
DATA
354 End data with <CR><LF>.<CR><LF>
Subject: Test
From: test@example.com
To: recipient@example.com

Test message body.
.
250 2.0.0 Ok: queued as ABC1234567
QUIT
221 2.0.0 Bye
```

What each step verifies:

- `220` banner = Postfix is listening and responding
- `250` response to `EHLO` = SMTP handshake works; capabilities listed
- `250` to `MAIL FROM` = sender accepted
- `250` to `RCPT TO` = recipient accepted (this is where most rejections happen)
- `354` = ready to receive message body
- `250 ... queued as` = message accepted and assigned a queue ID

If any step returns `4xx` or `5xx`, that’s your problem in plain text.

**Outbound test** (verify you can reach a remote MX):

```bash
nc smtp.google.com 25
```

You should immediately see a `220` banner from Google. If it hangs or refuses, you have a network/firewall problem (Step 8).

**Test with sendmail interface:**

```bash
echo "Subject: test
Body" | sendmail -v recipient@example.com
```

The `-v` shows the SMTP conversation with the remote server in real time.

**Address verification** (will Postfix accept this recipient?):

```bash
sudo sendmail -bv recipient@example.com
```

Returns whether the address would be accepted, without actually sending anything.

-----

## Quick triage flow

When mail isn’t flowing, run these four commands first:

```bash
sudo systemctl status postfix              # Is it running?
mailq | tail -1                            # How much is stuck?
sudo tail -50 /var/log/maillog             # What does it say?
sudo qshape deferred | head -10            # Where is it stuck?
```

Within 60 seconds these tell you: (1) whether Postfix is up, (2) how big the problem is, (3) what the immediate error is, and (4) whether the problem is destination-specific or general.

From there:

- **Queue empty but mail isn’t arriving** → Step 3 (logs will show rejection at `smtpd` stage)
- **Queue full, one destination dominates** → Step 8 (DNS/network) or Step 10 (reputation) for that destination
- **Queue full, all destinations** → Step 8 (general connectivity) or Step 1 (Postfix itself)
- **Lots of `4.7.x` codes** → Step 10 (reputation)
- **Lots of `4.4.x` codes** → Step 8 (network)
- **Lots of `5.1.x` codes** → bad recipient addresses, check the originating application
- **`mail transport unavailable`** → Step 7 (master.cf is broken or transport is down)
- **Postfix won’t start** → Step 1 (`journalctl -u postfix` and `postfix check`)
- **Sudden burst of outbound mail** → likely compromise; freeze suspect accounts and check `mailq` for unusual senders

The discipline that catches more problems than any single command: **always read the parenthesized text** in `mailq` and the actual SMTP response in the log. Postfix is unusually honest — it tells you what the remote server said, verbatim. Trust that text before guessing.

-----

## One-liner cheat sheet

Copy-paste-ready commands for fast triage. Replace `$QID` with a queue ID and `$DOMAIN` / `$IP` as appropriate.

### Service status

```bash
# Is Postfix running and listening?
sudo systemctl status postfix && sudo ss -tlnp | grep -E ':25|:465|:587'

# Verify Postfix's own status
sudo postfix status

# Check config syntax
sudo postfix check

# Reload after config changes (no connection drop)
sudo postfix reload

# Hard restart
sudo systemctl restart postfix

# Postfix version
postconf mail_version
```

### Queue inspection

```bash
# List the queue (traditional)
mailq
sudo postqueue -p

# Just the totals
sudo postqueue -p | tail -1

# Count messages by queue directory
sudo find /var/spool/postfix/{active,deferred,incoming,hold,corrupt} -type f 2>/dev/null | awk -F/ '{print $5}' | sort | uniq -c

# Just the deferred count (fast on huge queues)
sudo find /var/spool/postfix/deferred -type f | wc -l

# Top destinations in the deferred queue
sudo qshape deferred | head -20

# Active queue (should be near-empty in normal ops)
sudo qshape active | head -10

# Incoming queue (should be near-empty)
sudo qshape incoming | head -10

# Group queue by error reason
sudo mailq | awk '/^[ ]+\(/ {sub(/^[ ]+\(/,""); sub(/\)$/,""); print}' | sort | uniq -c | sort -rn | head -20

# Group queue by sender
sudo mailq | awk '/^[A-F0-9]/ {getline; print $0}' | sort | uniq -c | sort -rn | head -10

# Group queue by recipient domain
sudo mailq | awk '/@/ {for(i=1;i<=NF;i++) if($i ~ /@/) print $i}' | awk -F@ '{print $2}' | sort | uniq -c | sort -rn | head -10
```

### Specific message

```bash
# Trace one message through the log
sudo grep "$QID" /var/log/maillog

# Same, including rotated logs
sudo zgrep "$QID" /var/log/maillog*

# Decode a queued message (envelope + headers + body)
sudo postcat -vq "$QID"

# Force immediate delivery attempt
sudo postqueue -i "$QID"

# Delete a specific message
sudo postsuper -d "$QID"

# Hold (freeze) a message
sudo postsuper -h "$QID"

# Release a held message
sudo postsuper -H "$QID"

# Force the entire queue to retry now
sudo postqueue -f

# Requeue everything (re-runs cleanup; useful after config change)
sudo postsuper -r ALL

# Delete all deferred mail (careful!)
sudo postsuper -d ALL deferred

# Delete the entire queue (very careful!)
sudo postsuper -d ALL

# Delete all mail from a specific sender
sudo mailq | awk -v s='sender@example.com' '/^[A-F0-9]/{qid=$1; sender=$7} sender~s{print qid}' | sudo postsuper -d -
```

### Log reading

```bash
# Recent activity
sudo tail -100 /var/log/maillog
sudo journalctl -u postfix --since "30 minutes ago"

# Real-time watch
sudo tail -f /var/log/maillog

# Errors and warnings only
sudo grep -E 'postfix.*(panic|fatal|error|warning)' /var/log/maillog | tail -20

# Specifically qmgr issues (often most actionable)
sudo grep -E 'qmgr.*(panic|fatal|error|warning)' /var/log/maillog | tail -20

# All rejections
sudo grep 'NOQUEUE: reject' /var/log/maillog | tail -20

# All deferred deliveries today
sudo grep "$(date +%b\ %e)" /var/log/maillog | grep 'status=deferred' | tail -20

# Stats by status (sent / deferred / bounced)
sudo grep "$(date +%b\ %e)" /var/log/maillog | grep -oE 'status=[a-z]+' | sort | uniq -c

# Top deferral reasons today
sudo grep "$(date +%b\ %e)" /var/log/maillog | grep 'status=deferred' | grep -oE '\(.*\)' | sort | uniq -c | sort -rn | head -10

# Top destinations by message count today
sudo grep "$(date +%b\ %e)" /var/log/maillog | grep -oE 'to=<[^>]+>' | awk -F@ '{print $2}' | tr -d '>' | sort | uniq -c | sort -rn | head -10

# Pflogsumm summary (if installed: apt install pflogsumm)
sudo pflogsumm /var/log/maillog | less
```

### Configuration

```bash
# Show all non-default settings (what's customized)
sudo postconf -n

# Show specific parameter
sudo postconf myhostname mydestination mynetworks relayhost

# Default vs current value
diff <(sudo postconf -d | sort) <(sudo postconf | sort) | head -40

# Show all master.cf services
sudo postconf -M

# Show one specific master.cf service
sudo postconf -M smtp/inet

# Edit a parameter from CLI (then reload)
sudo postconf -e 'message_size_limit = 52428800' && sudo postfix reload

# Rebuild a hash map after editing
sudo postmap /etc/postfix/transport
sudo postmap /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/virtual

# Test a map lookup
sudo postmap -q "example.com" hash:/etc/postfix/transport
```

### DNS and connectivity

```bash
# MX lookup
dig +short MX $DOMAIN

# A fallback (when no MX)
dig +short A $DOMAIN

# Reverse DNS (PTR) of sending IP
dig +short -x $IP

# Confirm FCrDNS (forward matches reverse)
host $(dig +short -x $IP) | grep -q "$IP" && echo "FCrDNS OK" || echo "FCrDNS MISMATCH"

# Port 25 connectivity to a destination
nc -zv smtp.$DOMAIN 25

# Test outbound port 25 to Google (general "is port 25 blocked?" check)
nc -zv smtp.gmail.com 25

# DNS from Postfix's chrooted environment
sudo -u postfix dig +short MX $DOMAIN

# SPF
dig +short TXT $DOMAIN | grep spf

# DMARC
dig +short TXT _dmarc.$DOMAIN

# DKIM (replace SELECTOR with your selector, often 'default' or 'mail')
dig +short TXT SELECTOR._domainkey.$DOMAIN

# Check a few major blocklists
IP_REV=$(echo $IP | awk -F. '{print $4"."$3"."$2"."$1}')
for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
  r=$(dig +short $IP_REV.$bl)
  [ -n "$r" ] && echo "LISTED on $bl: $r" || echo "clean on $bl"
done
```

### Live SMTP testing

```bash
# Connect to local Postfix
telnet localhost 25

# Connect with STARTTLS
openssl s_client -connect localhost:25 -starttls smtp -crlf

# Connect to remote MX
openssl s_client -connect smtp.$DOMAIN:25 -starttls smtp -crlf

# Verbose send via sendmail interface
echo -e "Subject: test\n\nbody" | sendmail -v recipient@example.com

# Address verification (would Postfix accept this?)
sudo sendmail -bv recipient@example.com

# Send a test from the command line via Postfix
echo "test body" | mail -s "test subject" recipient@example.com
```

### Resource monitoring

```bash
# Disk space on queue partition
df -h /var/spool/postfix

# Inode usage on queue partition
df -i /var/spool/postfix

# Open files held by postfix user
sudo lsof -u postfix | wc -l

# Active SMTP connections
sudo ss -tnp state established '( sport = :25 or dport = :25 or sport = :587 or dport = :587 )'

# Watch connection count live
watch -n 1 "sudo ss -tn state established '( sport = :25 or sport = :587 )' | wc -l"

# Postfix process limits
sudo postconf default_process_limit smtpd_client_connection_count_limit smtpd_client_connection_rate_limit default_destination_concurrency_limit default_destination_rate_delay

# Queue growth rate (run twice 60s apart)
date && sudo find /var/spool/postfix/deferred -type f | wc -l
```

### Watch dashboards

```bash
# Live queue size
watch -n 5 "sudo postqueue -p | tail -1"

# Live queue + recent log
watch -n 3 "sudo postqueue -p | tail -1; echo; sudo tail -10 /var/log/maillog"

# Live qshape of deferred (find shifting hotspots)
watch -n 10 "sudo qshape deferred | head -15"

# Live status breakdown for current hour
watch -n 10 "sudo grep \"\$(date +'%b %e %H:')\" /var/log/maillog | grep -oE 'status=[a-z]+' | sort | uniq -c"
```