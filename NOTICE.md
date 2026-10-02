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
- (2026-10) `net.site.name` set to "Chess Puerto Rico Coffee" in
  `docker/conf/lila.conf.example`, so lila itself emits the site name in
  page titles and the header.
- (2026-10) Navigation/side-menu clean-up via `sub_filter`: the upstream
  Donate slots removed, "About", "News", "Is the site lagging?" and other
  labels rebranded, links to routes that do not exist on this deployment
  removed, the FAQ "contribute" answer pointed at the upstream Lichess
  project, and `Permissions-Policy` re-emitted without upstream hosts.
- (2026-10) Sponsor bar and AGPL footer styling moved from inline styles
  into `public/static/prcoffee/branding.css` (served at `/prcoffee/branding.css`).

## 2. Configuration

- **Caddyfile** (`caddy/Caddyfile`): Modified WebSocket matcher to use
  case-insensitive regex (`header_regexp Connection (?i)upgrade`) to fix
  connections not matching lowercase `Upgrade:` headers from nginx.
- **mono-caddy.conf** (`caddy/mono-caddy.conf`): Alternative Caddy
  config for single-container "mono" deployment mode. Not currently
  active; kept for reference and completeness of the deployment source.
- **nginx configs** (`nginx/`): Custom reverse-proxy config for the
  domain, plus a parallel system config file required by Plesk.
- **robots.txt** (`public/robots.txt`): Changed from upstream default
  `Disallow: /` to `Allow: /` for public search-engine indexing.
- **sitemap.xml** (`public/sitemap.xml`): Custom sitemap created for
  search indexing.
- **compose.yml** / **compose-search.yml** (`docker/`): Environment
  variable overrides for domain, URL, mail settings, and service
  profiles. Active profiles: base, stockfish-play, stockfish-analysis,
  search, gifs, external-engine, push, thumbnails, email. Elasticsearch
  heap reduced from the upstream default to `-Xms512m -Xmx512m` via
  `ES_JAVA_OPTS` to fit the deployment's RAM budget. Sensitive values
  replaced with placeholders in `.env.example` and `lila.conf.example`
  templates.
- **AGPL-3.0 attribution footer** (`nginx/snippets-chess-branding.conf`):
  A `sub_filter` injection appends a visible footer on every page with
  the text "This site is a modified version of Lichess, licensed under
  AGPL-3.0" and a clickable link to this public source-code repository
  (github.com/JoseLuisOcana/chess-puerto-rico-coffee-public). This is
  how AGPL-3.0 source-disclosure is exposed to end users. External
  anchor tags use `target="_blank" rel="noopener"` for security
  (prevents `window.opener` access) and UX (links open in new tabs).

- (2026-10) **SEO / headers** (`nginx/plesk-vhosts-chesspuertoricocoffee.com.conf`,
  `nginx/snippets-chess-branding.conf`): per-page meta description and Open Graph
  tags (og:url = the page's own URL), canonical `Link` header, Organization +
  WebSite JSON-LD on the homepage, HSTS, a `Content-Security-Policy-Report-Only`
  header, redirects (`/source` → this repository, `/patron`, `/swag`, `/contact`),
  `/favicon.ico` and `/prcoffee/` static assets. `public/robots.txt` is now the
  exact file served (it is returned inline by the vhost).
- (2026-10) **Crawler rate limiting** (`nginx/conf.d/chess-ratelimit.conf`):
  crawlers listed in robots.txt are served but rate-limited per crawler and kept
  off expensive paths. Also published: `nginx/snippets-dotfile-deny.conf`,
  `nginx/conf.d/*.conf` (http-context maps) and `nginx/vhost_nginx.conf.prestaging`
  (Plesk pre-staging copy of the vhost; not loaded today).
- (2026-10) **lila_push** VAPID subject changed to the site's own address
  (`docker/compose.yml`); MongoDB healthcheck script `docker/scripts/replica-set.js`
  enables mongod `quiet` mode.

## 3. Custom utilities

- **puzzle-import/import_puzzles.py**: Standalone Python script
  (no lila code imports) that parses the public Lichess puzzle CSV
  dataset and loads it into the local MongoDB in the schema expected
  by lila's puzzle reader.
- **ops/** (2026-10): deployment scripts and units — daily-puzzle recycling
  (`chess-recycle-daily-puzzles.sh` + cron), nightly MongoDB dump with read-back
  verification (`chess-mongodump.sh` + cron), and the contact-form service unit
  with its SMTP drop-in. E-mail addresses are sanitized.
- **contact-api/** (2026-10): the small Node.js contact-form backend
  (`server.js`, sends via authenticated SMTP; credentials come from an
  environment file that is not published; recipient address sanitized).

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

### modules/security/src/main/EmailConfirm.scala (2026-10)

The sign-up confirmation e-mail said "Confirm your lichess.org account":

- Subject: the translated string has "lichess.org" replaced with
  "Chess Puerto Rico Coffee" (covers every language).
- Body: the hardcoded `https://lichess.org` link points to this site.

### build.sbt (2026-10)

- `javaOptions` heap of the forked application JVM: `-Xmx512m` → `-Xmx2g`.

Each file is in `lila-modifications/` with an `.upstream.diff` generated with
`git diff` against the deployed upstream lila commit (`f9e0e4c`).

## Upstream versions

The deployment tracks the upstream Lichess repositories directly from
github.com/lichess-org. For the exact upstream commit currently deployed,
consult the docker-compose image tags in `docker/compose.yml`.

---

*Last updated: October 2026*
