# stampyx-infra

Deploys the Stampyx stack to the shared VPS. The deploy workflow builds nothing: it ships
`compose.prod.yaml`, the nginx config and the mail configs to the box from the commit being
deployed, and the images come from Artifact Registry.

`api`, `ui` and `landing` are published by their own repositories. The three mail images are
published by the deploy workflow itself, because the Dockerfiles that produce them live here.
There is one workflow in this repository, and it is `deploy.yml`.

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
alone — a deploy of the API alone does not restart Postfix, Dovecot or rspamd.

`api`, `ui` and `landing` take a SHA from the release run in their own repository. Mail is
different: the images are built from *this* repository, so instead of a tag you tick
**build_mail**, and the deploy builds the three at the commit it is running from and uses
that SHA. Leave `mail_tag` blank when you do. `mail_tag` is still there for the one case the
box cannot express — putting an *older* mail image back. `stampyx-api` migrations run **before** `up`, so a bad migration aborts the deploy
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
send path is tested locally. It reaches them at `../stampyx-infra/mail/docker`, a path that
only resolves on a machine with both repositories checked out side by side — which is why
stampyx-api cannot be the thing that publishes them.

Production pulls them from Artifact Registry, and the deploy's `build-mail` job is what puts
them there. It is skipped unless `build_mail` is ticked; when it runs, it builds `postfix`,
`dovecot` and `rspamd` and tags all three with the commit the deploy is running from. That
same run ships the `mail/` configs to the VPS, so image and config come from one commit
rather than two.

Nothing builds them on a push to `master`. A mail change reaches production when you deploy
it, which means a broken Dockerfile surfaces in the deploy run rather than at merge time. That SHA is the `MAIL_TAG` the deploy asks for. The
three share one tag on purpose — Postfix and Dovecot read the same SQL maps and the same
`MAIL_INTERNAL_SECRET`, so a mismatched pair is not a state worth being able to reach.

## Secrets and variables

Secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_SSH_KNOWN_HOSTS`, `GCP_PROJECT_ID`,
`APP_DB_PASSWORD`, `KEYCLOAK_ADMIN_CLIENT_SECRET`, `STAMPYX_PROVISIONING_SECRET`,
`STAMPYX_JWT_SECRET`, `MAIL_INTERNAL_SECRET`, `MAIL_MASTER_PASSWORD`, `MAIL_PUBLIC_IP`.

Variables: `API_LOG_LEVEL` (default `info`), `STAMPYX_ACCOUNT_AUTO_APPROVE` (default `true`).

There is no `GCP_SA_KEY` here — the VPS holds its own read-only registry login and the runner
never touches the registry.

`STAMPYX_PROVISIONING_SECRET` also lives in the **auth** repo's secrets, and
`KEYCLOAK_ADMIN_CLIENT_SECRET` lives there under the different name
`STAMPYX_KEYCLOAK_ADMIN_CLIENT_SECRET`. Nothing checks that either pair agrees. Rotating one
means updating both repositories and redeploying both stacks.

**VPS_SETUP.md section 10** has the full per-repository table, including what the three build
repos and the auth repo need.

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
