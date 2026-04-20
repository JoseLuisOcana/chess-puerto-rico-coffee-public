# Modifications from Upstream Lichess

This file documents all modifications to upstream Lichess for the
Chess Puerto Rico Coffee deployment, in fulfillment of AGPL-3.0
source-disclosure requirements.

## 1. Branding

- Site name changed from "Lichess" to "Chess Puerto Rico Coffee" via
  nginx `sub_filter` injection (see `nginx/snippets-chess-branding.conf`).
- Tab title, logo area, and footer modified to reference the sponsor
  (PuertoRicoCoffeeShop.com) and the Puerto Rico community.
- Homepage "Donate" and "Swag Store" boxes replaced with "Puzzle of
  the Day" and "Live Games" links.

## 2. Configuration

- **Caddyfile** (`caddy/Caddyfile`): Modified WebSocket matcher to use
  case-insensitive regex (`header_regexp Connection (?i)upgrade`) to fix
  connections not matching lowercase `Upgrade:` headers from nginx.
- **nginx configs** (`nginx/`): Custom reverse-proxy config for the
  domain, plus a parallel system config file required by Plesk.
- **robots.txt** (`public/robots.txt`): Changed from upstream default
  `Disallow: /` to `Allow: /` for public search-engine indexing.
- **sitemap.xml** (`public/sitemap.xml`): Custom sitemap created for
  search indexing.
- **compose.yml** / **compose-search.yml** (`docker/`): Environment
  variable overrides for domain, URL, mail settings, and service
  profiles. Sensitive values replaced with placeholders in the
  `.env.example` and `lila.conf.example` templates.

## 3. Custom utilities

- **puzzle-import/import_puzzles.py**: Standalone Python script
  (no lila code imports) that parses the public Lichess puzzle CSV
  dataset and loads it into the local MongoDB in the schema expected
  by lila's puzzle reader.

## 4. Custom static pages

Custom HTML pages for the deployment:
- `public/static/about.html`
- `public/static/contact-us.html`
- `public/static/privacy.html`
- `public/static/terms-of-service.html`

## 5. Direct modifications to lila source code

### modules/fishnet/src/main/FishnetPlayer.scala

Reduced the AI opponent thinking delay to improve "Play vs Computer"
responsiveness, especially on mobile devices:

- `delayFactor`: 0.011f → 0.003f (~73% faster responses)
- Opening move delay: 2 seconds → 1 second
- Maximum delay cap: 5 seconds → 2 seconds

See `lila-modifications/modules/fishnet/src/main/FishnetPlayer.scala`
and the accompanying `.upstream.diff` for the exact changes.

## Upstream versions

The deployment tracks the upstream Lichess repositories. Exact commit
SHAs of the running version are recorded in `docker/versions.txt`,
updated after each deployment (when present).

---

*Last updated: April 2026*
