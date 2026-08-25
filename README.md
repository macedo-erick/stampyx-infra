# stampyx-infra

Deploys the Stampyx stack to the shared VPS. It builds nothing: the workflow ships
`compose.prod.yaml`, the nginx config and the mail configs to the box from the commit being
deployed, and the images come from Artifact Registry.

## The model

One Ubuntu VPS. nginx and PostgreSQL 17 run on the host; applications run as a Compose
project. Every web container binds `127.0.0.1` — the mail containers are the exception, and
that exception is the whole reason this stack is different from planelyx and listryx.

```
https://stampyx.com/         -> 127.0.0.1:8094   stampyx-landing
https://stampyx.com/ui/      -> 127.0.0.1:8090   stampyx-ui
https://stampyx.com/api/     -> 127.0.0.1:8091   stampyx-api  (+ WebSocket upgrade)
https://stampyx.com/auth/    -> 127.0.0.1:8085   the shared Keycloak

0.0.0.0:25   inbound SMTP        postfix
0.0.0.0:587  submission (TLS)    postfix
0.0.0.0:465  SMTPS               postfix
0.0.0.0:993  IMAPS               dovecot
```

Compose project `stampyx`, subnet `172.23.0.0/16` — matching the host `pg_hba.conf` entry and
the ufw rule. planelyx is `172.20`, auth `172.21`, listryx `172.22`.

## Deploying

Run the `deploy` workflow and give it the tags to move. A blank tag leaves that service
alone. `stampyx-api` migrations run **before** `up`, so a bad migration aborts the deploy
rather than reaching a running container.

Roll back by re-running with the previous tags; the summary of every run records them.

## What the smoke checks assert

Beyond "it answers", the checks prove things that have silently broken before:

- `/api/domains` returns **exactly 401** — the port answering is not evidence the auth guard
  is mounted.
- `/metrics`, `/health` and `/internal/mail/` return **404** publicly.
- Submission on 587 presents a certificate, and 25 and 993 answer at all.
- `https://listryx.com/ui/` still serves, because the nginx reload is shared.

## The mail images

`mail/docker/` holds the Dockerfiles for `postfix`, `dovecot` and `rspamd`. None of them bake
the configuration in: each entrypoint renders `mail/postfix/`, `mail/dovecot/` and
`mail/rspamd/local.d/` at start, so the files above are the single source of truth and a
change to them is exercised by the developer stack before it is deployed.

`stampyx-api/compose.yaml` builds these three and runs them next to the API, which is how the
send path is tested locally. Production still pulls the images from Artifact Registry: this
repository's deploy workflow builds nothing.

## Secrets and variables

Secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_SSH_KNOWN_HOSTS`, `GCP_PROJECT_ID`,
`APP_DB_PASSWORD`, `KEYCLOAK_ADMIN_CLIENT_SECRET`, `STAMPYX_PROVISIONING_SECRET`,
`MAIL_INTERNAL_SECRET`, `MAIL_MASTER_PASSWORD`, `MAIL_PUBLIC_IP`.

Variables: `API_LOG_LEVEL` (default `info`).

There is no `GCP_SA_KEY` here — the VPS holds its own read-only registry login and the runner
never touches the registry.

`STAMPYX_PROVISIONING_SECRET` also lives in the **auth** repo's secrets, and nothing checks
that the two copies agree. Rotating it means updating both repositories and redeploying both
stacks.

## Layout

```
compose.prod.yaml                  the stack
nginx/stampyx.conf                 -> /etc/nginx/sites-available/stampyx
nginx/snippets/stampyx-proxy.conf  -> /etc/nginx/snippets/
nginx/snippets/keycloak-proxy.conf reference only; the auth repo owns the live file
mail/postfix/                      main.cf, master.cf additions, the four pgsql maps
mail/dovecot/                      dovecot.conf, the SQL passdb, the Sieve notify script
mail/rspamd/local.d/               DKIM signing, milter proxy, actions, Bayes
mail/docker/                       the three mail images, and the local dev certificate
.env.example                       reference; the workflow renders the real one
```
