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

## 3. The port-80 vhost must exist before certbot

`catch-all.conf` (owned by the auth repo) returns **444 on port 80** for any unknown host. So
`stampyx.com`'s own port-80 server block has to be installed and enabled *first*, or the ACME
challenge is never answered and certbot fails with a misleading connection error.

```bash
sudo cp nginx/stampyx.conf /etc/nginx/sites-available/stampyx
sudo ln -s /etc/nginx/sites-available/stampyx /etc/nginx/sites-enabled/stampyx
sudo nginx -t && sudo systemctl reload nginx

sudo certbot certonly --webroot -w /var/www/certbot -d stampyx.com -d www.stampyx.com
sudo certbot certonly --webroot -w /var/www/certbot -d mail.stampyx.com
```

The mail certificate is separate because Postfix and Dovecot mount it directly, and mounting
the whole `/etc/letsencrypt` into a mail container would hand it every other product's key.

Add a renewal hook so the mail containers pick up a new certificate:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/stampyx-mail.sh >/dev/null <<'EOF'
#!/bin/sh
cd /home/<deploy-user>/stampyx-infra && docker compose -f compose.prod.yaml restart postfix dovecot
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/stampyx-mail.sh
```

## 4. Postgres role and database

```sql
CREATE ROLE stampyx_app LOGIN PASSWORD '<app-password>';
CREATE DATABASE stampyx OWNER stampyx_app;
```

```conf
# /etc/postgresql/17/main/pg_hba.conf — must match the ipam block in compose.prod.yaml
host  stampyx  stampyx_app  172.23.0.0/16  scram-sha-256
```

```bash
sudo ufw allow from 172.23.0.0/16 to any port 5432 proto tcp
sudo systemctl restart postgresql   # restart, not reload: listen_addresses needs it
```

A role of its own, not a shared one. If `stampyx_app` is compromised it must not be a path
into `planelyx`, `listryx` or `keycloak`.

**Both layers are required, and they fail differently:**

| Missing | What you see | Why |
|---|---|---|
| the `ufw` rule | a connection timeout naming nothing | `default deny incoming` **drops** the packets |
| the `pg_hba` line | `FATAL: no pg_hba.conf entry for host "172.23.0.2"` | Postgres accepted, then refused by name |

A timeout is the firewall. An error that names the address is `pg_hba.conf`.

## 5. nginx files the deploy user may write

The workflow installs an explicit list of files, never a directory sync.

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

## 10. Order of operations, first deploy

1. Port 25 confirmed (section 1)
2. DNS + PTR (section 2)
3. port-80 vhost, then certbot (section 3)
4. Postgres role, pg_hba, ufw (section 4)
5. nginx ownership and sudoers (section 5)
6. mail ports (section 6)
7. deploy the **auth** stack so the realm exists (section 7)
8. Artifact Registry repo `stampyx` with per-repository IAM — writer for the build service
   account, reader for the VPS pull account. Repository-level IAM does not inherit.
9. run this repo's `deploy` workflow with every tag supplied
