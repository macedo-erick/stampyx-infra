# VPS setup for stampyx

One-time manual work, in order. The deploy workflow assumes all of it is done.

Written as a runbook: it records the failure modes that cost real time, not just the happy
path.

---

## 1. Confirm port 25 is open — before anything else

Ask the VPS provider to unblock outbound port 25, and get the answer in writing.

```bash
# From the VPS. If this hangs, 25 is blocked outbound.
timeout 10 nc -vz gmail-smtp-in.l.google.com 25
```

This decides whether the project runs on this box at all. Hetzner and DigitalOcean usually
unblock on request; several budget providers never will. **Do not build anything else until
this is answered** — every other step is wasted if the answer is no.

## 2. DNS and the PTR record

Point `stampyx.com` and `mail.stampyx.com` at the VPS. Then set the **PTR** (reverse DNS) for
the IP to `mail.stampyx.com` — this is done in the VPS provider's control panel, not in the
domain's DNS zone, which is why it is the check most often missed.

```bash
dig +short -x <the IP>     # must print mail.stampyx.com.
```

Almost every large receiver rejects mail from an IP with no matching PTR. The API's
`dns-check` endpoint reports it, but it cannot fix it.

## 3. nginx: the snippet first, then the certificate chicken-and-egg

`stampyx.conf` cannot be installed in one step on a fresh box. It fails twice, and both times
`nginx -t` names a file rather than the reason:

- it `include`s `/etc/nginx/snippets/stampyx-proxy.conf` five times, and **nothing else
  creates that file** — not even the deploy workflow, which refuses to run when it is absent
  rather than creating it;
- its two `443` blocks reference `/etc/letsencrypt/live/stampyx.com/`, which does not exist
  until certbot has run — and certbot cannot run until a port-80 vhost is already answering
  the ACME challenge.

So the order below is not optional: snippet, port-80-only vhost, certificates, real vhost.

`catch-all.conf` (owned by the auth repo) returns **444 on port 80** for any unknown host,
which is why the challenge is never answered by accident — `stampyx.com`'s own port-80 block
has to be serving first.

### 3a. The proxy snippet

```bash
sudo cp nginx/snippets/stampyx-proxy.conf /etc/nginx/snippets/stampyx-proxy.conf
```

> `open() "/etc/nginx/snippets/stampyx-proxy.conf" failed (2: No such file or directory)`
> is this step having been skipped.

`keycloak-proxy.conf` is included by `stampyx.conf` as well, but the **auth** repo owns the
live file — do not install this repo's copy over it. If `nginx -t` reports *that* path
missing, the auth stack's nginx files are not on the box yet; install those first.

### 3b. A port-80-only vhost, purely to get the certificate

Not `nginx/stampyx.conf` yet — its `443` blocks would fail the test for want of a certificate
that this step exists to obtain.

**All three names go in `server_name`, `mail.stampyx.com` included.** Two certificates are
issued in 3c and both are validated over this one vhost. A name missing here is not a 404: it
matches no `server_name`, so the auth repo's `default_server` catch-all answers it with
`return 444`, and certbot reports the closed connection as `Error getting validation data`.

```bash
sudo mkdir -p /var/www/certbot
sudo tee /etc/nginx/sites-available/stampyx >/dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name stampyx.com www.stampyx.com mail.stampyx.com;

    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF
sudo ln -s /etc/nginx/sites-available/stampyx /etc/nginx/sites-enabled/stampyx
sudo nginx -t && sudo systemctl reload nginx
```

Prove the webroot is reachable from the internet before spending a rate-limit attempt on it:

```bash
echo ok | sudo tee /var/www/certbot/.well-known/acme-challenge/probe >/dev/null
curl -sS http://mail.stampyx.com/.well-known/acme-challenge/probe    # must print: ok
curl -sS http://stampyx.com/.well-known/acme-challenge/probe         # must print: ok
sudo rm /var/www/certbot/.well-known/acme-challenge/probe
```

An empty reply rather than `ok` is the catch-all: that name is not in `server_name` above, or
nginx was not reloaded. Let's Encrypt allows **5 failed validations per hostname per hour**,
so fix the probe first.

### 3c. The certificates

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d stampyx.com -d www.stampyx.com
sudo certbot certonly --webroot -w /var/www/certbot -d mail.stampyx.com
```

The mail certificate is separate because Postfix and Dovecot mount it directly, and mounting
the whole `/etc/letsencrypt` into a mail container would hand it every other product's key.

### 3d. The real vhost

Only now does the file in this repo pass a config test:

```bash
sudo cp nginx/stampyx.conf /etc/nginx/sites-available/stampyx
sudo nginx -t && sudo systemctl reload nginx
```

From here on the deploy workflow keeps both files up to date — see section 5 for the
ownership that lets it.

### 3e. The renewal hook

So the mail containers pick up a renewed certificate:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/stampyx-mail.sh >/dev/null <<'EOF'
#!/bin/sh
cd /home/<deploy-user>/stampyx-infra && docker compose -f compose.prod.yaml restart postfix dovecot
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/stampyx-mail.sh
```

Then prove renewal works now, rather than discovering in 60 days that it does not:

```bash
sudo certbot renew --dry-run
```

Both certificates must pass. `mail.stampyx.com` renews over the same webroot as the product
domain, which is why it is in the port-80 `server_name` of `nginx/stampyx.conf` — a dry run
that fails only for that name means the real vhost of 3d has not been installed.

## 4. Postgres role and database

Postgres runs on the **host**, not in this stack. The containers reach it through
`host.docker.internal`, which `compose.prod.yaml` maps to the Docker host gateway.

### 4a. Getting a psql prompt

There is no password for the `postgres` superuser and you do not need one: the local socket
uses **peer** authentication, so becoming the `postgres` OS user is the login.

```bash
sudo -u postgres psql                 # superuser prompt, for the steps below
sudo -u postgres psql -d stampyx      # straight into this product's database
```

Useful once you are in: `\l` lists databases, `\du` lists roles, `\c stampyx` switches
database, `\dt` lists tables, `\q` quits.

To connect **as the application role**, the way a container does — this exercises
`pg_hba.conf` and the password, which the peer login above does not:

```bash
psql "postgresql://stampyx_app:<app-password>@127.0.0.1:5432/stampyx" -c 'select current_user'
```

The server's own log is where a rejected connection explains itself:

```bash
sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

### 4b. The role and the database

```sql
CREATE ROLE stampyx_app LOGIN PASSWORD '<app-password>';
CREATE DATABASE stampyx OWNER stampyx_app;
```

`<app-password>` is the value of the `APP_DB_PASSWORD` secret (section 10). Nothing checks
that the two agree; a mismatch surfaces only as a failed login at deploy time.

The `OWNER` clause is not cosmetic. Since PostgreSQL 15 the `public` schema is writable only
by the database owner, so a database created with the wrong owner takes the API's migrations
all the way to `permission denied for schema public`.

A role of its own, not a shared one. If `stampyx_app` is compromised it must not be a path
into `planelyx`, `listryx` or `keycloak`.

### 4c. Letting the containers in — three layers

Listening, `pg_hba.conf` and `ufw`. All three are required.

```conf
# /etc/postgresql/17/main/postgresql.conf
# Without this Postgres binds the loopback only, and the Docker bridge address is not it.
listen_addresses = '*'
```

`'*'` is safe here *because of* the next two layers: `ufw` default-denies incoming, and
`pg_hba.conf` names one database, one role and one subnet.

```conf
# /etc/postgresql/17/main/pg_hba.conf — must match the ipam block in compose.prod.yaml
host  stampyx  stampyx_app  172.23.0.0/16  scram-sha-256
```

```bash
sudo ufw allow from 172.23.0.0/16 to any port 5432 proto tcp
sudo systemctl restart postgresql   # restart, not reload: listen_addresses needs it
sudo ss -lntp | grep 5432           # must show 0.0.0.0:5432, not 127.0.0.1:5432
```

**The three fail differently, which is how you tell them apart:**

| Missing | What you see | Why |
|---|---|---|
| `listen_addresses` | `connection refused` immediately | nothing is bound on that address |
| the `ufw` rule | a connection timeout naming nothing | `default deny incoming` **drops** the packets |
| the `pg_hba` line | `FATAL: no pg_hba.conf entry for host "172.23.0.2"` | Postgres accepted, then refused by name |
| a wrong `APP_DB_PASSWORD` | `FATAL: password authentication failed for user "stampyx_app"` | all three layers passed; the credential did not |

An instant refusal is `listen_addresses`. A timeout is the firewall. An error that names the
address is `pg_hba.conf`.

Verify the whole path from a container on the stack's own network, which is the only check
that exercises every layer at once:

```bash
docker run --rm --network stampyx_stampyx \
    --add-host host.docker.internal:host-gateway postgres:17 \
    psql "postgresql://stampyx_app:<app-password>@host.docker.internal:5432/stampyx" \
    -c 'select 1'
```

## 5. nginx files the deploy user may write

The workflow installs an explicit list of files, never a directory sync — and it **replaces**
files, never creates them. Both paths below must already exist from section 3, or the deploy
fails with `does not exist` before it touches nginx.

```bash
sudo chown <deploy-user>:<deploy-user> \
    /etc/nginx/sites-available/stampyx \
    /etc/nginx/snippets/stampyx-proxy.conf
```

```
# /etc/sudoers.d/stampyx-deploy
<deploy-user> ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /bin/systemctl reload nginx
```

Deliberately not blanket `NOPASSWD`: a leaked deploy key then buys a config test and a
reload, not root.

`keycloak-proxy.conf` is **not** in this list. The auth repo owns the live file; the copy in
this repo is reference only. `stampyx.conf` includes it, so deleting it would fail the next
`nginx -t`.

## 6. Opening the mail ports — the Docker/ufw trap

This is the first stack on this box with containers that are not loopback-only.

Docker writes its own iptables rules and **bypasses ufw entirely**, so `ufw deny` will not
stop traffic to a published container port, and `ufw allow` is not what is letting it
through. Published mail ports are already reachable; the rules that actually constrain them
belong in `DOCKER-USER`:

```bash
sudo ufw allow 25/tcp
sudo ufw allow 465/tcp
sudo ufw allow 587/tcp
sudo ufw allow 993/tcp
```

Verify from **outside** the box, not from the VPS itself — a local check passes even when the
provider is filtering:

```bash
nc -vz stampyx.com 25
nc -vz stampyx.com 587
nc -vz stampyx.com 993
```

## 7. Keycloak realm

The `stampyx` realm lives in the **auth** repo (`realms/stampyx.json`). Deploy that stack
first.

> ### A realm imports exactly once
> `--import-realm` is a **no-op for a realm the database already has**, and the `${VAR}`
> substitutions resolve only during that first import. Get `stampyx.json` right *before*
> first boot. In particular, if `STAMPYX_KEYCLOAK_ADMIN_CLIENT_SECRET` is unset at that
> moment, production ends up with a `manage-users` service account whose secret is
> `local-dev-secret`, published in a repository. Everything after that — a client added
> later, `eventsListeners`, the SMTP block — has to be done by hand in the admin console.

Stampyx is the first realm with `verifyEmail: true`, because it is the first one with an SMTP
server to send through: its own. That also means the mail plane must be working before the
realm is imported, or the first registration silently fails to send.

## 8. Storage and backups

`/data/vmail` is the only volume whose loss is unrecoverable — it holds actual mail, and
nothing else has a copy.

```bash
docker run --rm -v stampyx_vmail:/vmail -v /backup:/backup alpine \
    tar -czf "/backup/vmail-$(date +%F).tar.gz" -C /vmail .
```

**Test the restore.** A backup that has never been restored is a hypothesis. Restore into a
scratch volume and open a mailbox with `doveadm` before believing it.

`/data/attachments` matters less: those bytes were also delivered to the recipient.

## 9. Adding stampyx to the neighbours' checks

Both sibling stacks assert that their neighbour still serves after an nginx reload. Add
`https://stampyx.com/` as the `NEIGHBOUR_URL` in one of them so the check is reciprocal.

## 10. Secrets and variables, per repository

Four repositories feed this box, and they do not use the same names for the same value. Set
these in **Settings -> Secrets and variables -> Actions**; this repo's `deploy` workflow reads
them from the `production` environment.

### stampyx-infra (this repo)

| Secret | What it is | Must agree with |
|---|---|---|
| `VPS_HOST`, `VPS_USER` | where to ssh, as whom | the deploy user of section 5 |
| `VPS_SSH_KEY` | that user's private key | — |
| `VPS_SSH_KNOWN_HOSTS` | `ssh-keyscan <host>` output | the box's host key |
| `GCP_PROJECT_ID` | project holding the `stampyx` Artifact Registry repo | the build repos' own `GCP_PROJECT_ID` |
| `APP_DB_PASSWORD` | password of the `stampyx_app` role | section 4b |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | secret of the `stampyx-api-admin` client | auth's `STAMPYX_KEYCLOAK_ADMIN_CLIENT_SECRET` |
| `STAMPYX_PROVISIONING_SECRET` | signs the Keycloak -> API provisioning callback | auth's `STAMPYX_PROVISIONING_SECRET` |
| `STAMPYX_JWT_SECRET` | signs mailbox users' panel tokens; **>= 32 chars** | nothing — `openssl rand -base64 48` |
| `MAIL_INTERNAL_SECRET` | shared by api, postfix and dovecot | within this stack only |
| `MAIL_MASTER_PASSWORD` | the Dovecot master user's password | within this stack only |
| `MAIL_PUBLIC_IP` | the IP the PTR resolves to | section 2 |

| Variable | Default | Notes |
|---|---|---|
| `API_LOG_LEVEL` | `info` | a pino level: `trace`…`fatal` |
| `STAMPYX_ACCOUNT_AUTO_APPROVE` | `true` | Phase 8 sets this to `false` |

No `GCP_SA_KEY` here: the VPS holds its own read-only registry login and the runner never
touches the registry.

**A value containing a single quote breaks the whole stack** — `.env` has no escape for one —
so the workflow rejects it up front. Generate secrets with `openssl rand -base64 48`.

### stampyx-api, stampyx-ui, stampyx-landing

Build-and-push only. Two secrets each, and nothing else:

| Secret | What it is |
|---|---|
| `GCP_SA_KEY` | JSON key of the service account with **writer** on the `stampyx` repo |
| `GCP_PROJECT_ID` | same project as this repo's |

Each `release` run prints the tag to hand to this repo's `deploy` workflow.

### auth

Only the stampyx-facing ones are listed; that repo also carries planelyx's and listryx's.

| Secret there | Value | Note |
|---|---|---|
| `STAMPYX_KEYCLOAK_ADMIN_CLIENT_SECRET` | = this repo's `KEYCLOAK_ADMIN_CLIENT_SECRET` | **the names differ** |
| `STAMPYX_PROVISIONING_SECRET` | = this repo's `STAMPYX_PROVISIONING_SECRET` | same name, same value |
| `STAMPYX_SMTP_PASSWORD` | password of the `keycloak@stampyx.com` mailbox | a mailbox *this* stack serves |

Nothing verifies that either copy of a shared value matches. Rotating one means updating both
repositories and redeploying both stacks — and for the two that are baked into the realm at
import, see the warning in section 7: after first boot they can only be changed in the admin
console.

## 11. Order of operations, first deploy

1. Port 25 confirmed (section 1)
2. DNS + PTR (section 2)
3. proxy snippet, port-80-only vhost, certbot, then the real vhost (section 3)
4. Postgres role, `listen_addresses`, `pg_hba`, ufw (section 4)
5. nginx ownership and sudoers (section 5)
6. mail ports (section 6)
7. Artifact Registry repo `stampyx` with per-repository IAM — writer for the build service
   accounts, reader for the VPS pull account. Repository-level IAM does not inherit.
8. secrets and variables in all four repositories (section 10) — before the first run of any
   workflow, since the realm bakes two of them in at import
9. deploy the **auth** stack so the realm exists (section 7)
10. `release` in stampyx-api, stampyx-ui and stampyx-landing; note the four tags
11. run this repo's `deploy` workflow with **every** tag supplied — it refuses a first deploy
    with any tag blank
