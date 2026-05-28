# Nolbir Chatwoot — Production Deployment Guide

This document describes how to deploy the `nolbir-io/chatwoot` fork on a single
server and run it as a **multi-tenant** Chatwoot installation (one Chatwoot
instance, multiple Accounts — each Account is one tenant).

> Stack: Docker Compose · PostgreSQL (pgvector) · Redis · Rails web · Sidekiq worker
> Image: Built from this fork's root `Dockerfile`, published to `ghcr.io/nolbir-io/chatwoot`

---

## 1. Repository sync workflow (do this before every release)

Always rebase the fork on `chatwoot/develop` and **never push to the upstream
`chatwoot` remote** — push only to `origin` (`nolbir-io`).

```bash
git fetch chatwoot --prune
git fetch origin --prune

git tag "backup/origin-main-$(date +%Y%m%d)" origin/main

git checkout -B sync-fork chatwoot/develop
git merge --squash --no-commit origin/main

# If any translation customization (e.g. Uzbek entry in
# config/initializers/languages.rb) is dropped by an upstream change, re-add it
# in this step before committing.

git commit -m "chore(sync): rebase fork onto chatwoot/develop"

git branch -f main sync-fork
git checkout main
git push origin main --force-with-lease
git push origin "backup/origin-main-$(date +%Y%m%d)"
```

The CI workflow at `.github/workflows/main.yml` listens on the `develop`
branch — if you want pushes to `main` to trigger the image build, update the
workflow trigger, or push from `main` to `develop`:

```bash
git push origin main:develop
```

---

## 2. Server prerequisites (one-time)

- Linux host (Ubuntu 22.04+ tested), 4 GB RAM minimum (8 GB+ recommended)
- Docker 24+ and Docker Compose v2
- Reverse proxy / TLS: Nginx + Certbot (or Caddy / Traefik)
- DNS pointing each tenant's (sub)domain to the server

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-plugin nginx certbot python3-certbot-nginx
sudo usermod -aG docker $USER
```

---

## 3. Production directory layout on the server

```
/chatwoot/
├── docker-compose.production.yaml   # copy from this repo
├── .env                              # production secrets — NEVER commit real values
└── data/                             # docker volumes (auto-managed)
```

Pull the repo (or just copy `docker-compose.production.yaml`) to `/chatwoot`:

```bash
sudo mkdir -p /chatwoot && cd /chatwoot
git clone https://github.com/nolbir-io/chatwoot.git src
cp src/docker-compose.production.yaml .
cp src/.env .env   # then EDIT — see next section
```

---

## 4. Production `.env` — required overrides

The `.env` file in the repo is a template with placeholders. On the server,
edit `/chatwoot/.env` and set **at minimum**:

```dotenv
# Identity & security
SECRET_KEY_BASE=<run: openssl rand -hex 64>
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=<from: rails db:encryption:init>
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=<from: rails db:encryption:init>
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=<from: rails db:encryption:init>

# Hostnames
FRONTEND_URL=https://chat.nolbir.io       # the primary admin/login domain
FORCE_SSL=true
RAILS_ENV=production
NODE_ENV=production
INSTALLATION_ENV=docker

# Postgres
POSTGRES_HOST=postgres
POSTGRES_DATABASE=chatwoot_production
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=<strong random password>

# Redis
REDIS_URL=redis://redis:6379
REDIS_PASSWORD=<strong random password>

# Mail (replace with your real SMTP)
MAILER_SENDER_EMAIL=Nolbir Chat <no-reply@nolbir.io>
SMTP_ADDRESS=smtp.yourprovider.com
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_PORT=587
SMTP_AUTHENTICATION=plain
SMTP_ENABLE_STARTTLS_AUTO=true

# Image override (defaults to ghcr.io/nolbir-io/chatwoot:latest)
# CHATWOOT_IMAGE=ghcr.io/nolbir-io/chatwoot:v1.0.0
```

Generate the encryption keys once locally:

```bash
docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:encryption:init
```

Copy the three printed keys into the `.env`.

---

## 5. Image strategy — build from this fork

The custom Uzbek translations and enterprise toggle ship **only** when the
image is built from this fork. Two equivalent options:

### Option A — Pull pre-built image from GHCR (preferred)

The `.github/workflows/main.yml` workflow builds and pushes to
`ghcr.io/nolbir-io/chatwoot:<tag>` on every push to `develop`. The compose
file defaults to that image:

```yaml
image: ${CHATWOOT_IMAGE:-ghcr.io/nolbir-io/chatwoot:latest}
```

To pull from a private GHCR image, log in once on the server:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
```

### Option B — Build locally on the server

If you prefer to skip GHCR, replace the `image:` line with `build:` in
`docker-compose.production.yaml`:

```yaml
base: &base
  build:
    context: ./src        # path to the cloned fork
    dockerfile: Dockerfile
  env_file: .env
```

Then `docker compose -f docker-compose.production.yaml build`.

---

## 6. First-time start

```bash
cd /chatwoot

# Initialise the DB (once)
docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:chatwoot_prepare

# Boot
docker compose -f docker-compose.production.yaml up -d

# Tail logs
docker compose -f docker-compose.production.yaml logs -f rails sidekiq
```

The Rails web service binds to `127.0.0.1:3000` — front it with Nginx.

---

## 7. Nginx + TLS for the primary domain

`/etc/nginx/sites-available/chat.nolbir.io`:

```nginx
server {
  listen 80;
  server_name chat.nolbir.io;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl http2;
  server_name chat.nolbir.io;

  ssl_certificate     /etc/letsencrypt/live/chat.nolbir.io/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/chat.nolbir.io/privkey.pem;

  client_max_body_size 50m;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        "upgrade";
    proxy_read_timeout 86400;
  }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/chat.nolbir.io /etc/nginx/sites-enabled/
sudo certbot --nginx -d chat.nolbir.io
sudo systemctl reload nginx
```

---

## 8. Multi-tenancy model

This deployment uses Chatwoot's **built-in account-based multi-tenancy** —
one Rails install, one DB, one Redis, but multiple isolated `Account` rows.
Each Account has its own:

- Users (agents and admins)
- Inboxes (channels)
- Conversations / contacts
- Webhooks, automations, custom attributes
- Optional custom domain (the help center can be served from
  `<tenant>.yourdomain.com`)

### Provisioning a new tenant

1. Sign in to **Super Admin** at `https://chat.nolbir.io/super_admin` with
   the user flagged as `super_admin` in the DB.
2. Click **Accounts → New Account**.
3. Enter the tenant name and the email of the initial owner. Chatwoot
   emails them an invitation.
4. (Optional) Configure a per-account custom domain:
   - In Super Admin → Accounts → Edit → set `Custom Brand Domain`.
   - Point a DNS CNAME for that subdomain to the server.
   - Add it as a new Nginx `server_name` (re-using the same upstream
     `127.0.0.1:3000` block) and run certbot for that domain.

A quick way to seed sample data for a tenant during dev/staging:

```bash
docker compose -f docker-compose.production.yaml exec rails \
  bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"
```

### Why NOT multiple isolated Docker stacks?

You picked the single-install option. If a future client requires hard
DB/Redis isolation (regulatory, data sovereignty), spin up a second
Docker Compose stack with its own project name and override ports:

```bash
COMPOSE_PROJECT_NAME=chatwoot-tenant-b \
  docker compose -f docker-compose.production.yaml \
  -p chatwoot-tenant-b up -d
```

(Override `FRONTEND_URL`, host port mappings, and volume names in a
separate `.env.tenant-b`.)

---

## 9. Upgrades

On each new image release (after a rebase + CI build):

```bash
cd /chatwoot
git -C src pull
docker compose -f docker-compose.production.yaml pull
docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:chatwoot_prepare
docker compose -f docker-compose.production.yaml up -d
```

The CI workflow at `.github/workflows/main.yml` automates this via SSH on
the server — make sure the GitHub secrets `DROPLET_IP`, `DROPLET_USERNAME`,
and `SSH_PRIVATE_KEY` are set in the `nolbir-io/chatwoot` repo settings.

---

## 10. Notes & known caveats

- **`.env` is committed in the fork** with placeholder values. The
  committed file must NEVER be edited with real production secrets — keep
  real secrets only in `/chatwoot/.env` on the server. Consider moving
  the committed template to `.env.example` to avoid future mistakes.
- The repo's CI workflow triggers on the `develop` branch, not `main`.
  Push `main → develop` or update the workflow trigger to deploy from
  `main`.
- Backup tag for the most recent fork sync:
  `backup/origin-main-pre-rebase-20260528` — can be restored via
  `git push origin backup/origin-main-pre-rebase-20260528:main --force-with-lease`.
- For uploaded files / Active Storage, the default is `local` (stored in
  the `storage_data` Docker volume). For multi-server scaling or S3
  durability, switch `ACTIVE_STORAGE_SERVICE` to `amazon` and fill the
  `S3_BUCKET_NAME` / `AWS_*` values.
