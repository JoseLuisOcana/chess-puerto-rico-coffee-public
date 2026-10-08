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
- (2026-10) **HTTP/2** enabled on the TLS listener (`http2` on the vhost's `listen … ssl` lines,
  nginx 1.18 syntax) and a server-side TLS session cache (`nginx/conf.d/ssl-session-cache.conf`).
  WebSocket connections still use the HTTP/1.1 upgrade path.
- (2026-10) Sponsor bar and AGPL footer styling moved from inline styles
  into `public/static/prcoffee/branding.css` (served at `/prcoffee/branding.css`).
- (2026-10) **Homepage "Chess Videos" strip:** `public/static/prcoffee/videos.js` (loaded on the
  homepage only, via `$chess_videos` in the vhost and the `</head>` rule in the branding snippet)
  renders the 4 newest videos of lila's own video library as cards linking to the site's own
  `/video/<id>` pages; styles in `branding.css`. Its data file and thumbnails are written weekly by
  `ops/chess-video-refresh.sh`, which adds new long-form videos only from the YouTube channels in
  `ops/chess-video-channels.json` (public RSS feeds, no API key; Shorts and live streams skipped;
  max 2 per channel per week; titles must pass `ops/chess-video-blocklist.json` - profanity, sexual or
  violent words, "mate" puns, with real chess terms allowed - and YouTube must report the video as
  embeddable and not age-restricted) and serves thumbnails locally. Thumbnails and `videos.json` are
  generated data (the thumbnails belong to the video creators) and are not part of this repository.
- (2026-10) **Sign-up age confirmation:** a required checkbox "I am 13 or older (or have parental
  consent)." is added to lila's sign-up form by the nginx branding snippet (`sub_filter` at the end of the
  agreement checkboxes, only on `/signup`); `public/static/prcoffee/signup.js` re-adds it if the anchor ever
  moves and shows a clear message. The box has no `name`, so lila's server code is unchanged. The privacy
  page (`public/static/privacy.html`) describes it and the embedded YouTube videos.
- (2026-10) **Video embeds:** lila already embeds YouTube in privacy-enhanced mode (youtube-nocookie.com);
  the branding snippet corrects the player's hardcoded `origin=https://lichess.org` to this site's domain.
- (2026-10) **Weekly health report:** `ops/chess-health-report.sh` + cron (Mondays) e-mails a read-only
  summary (backups, disk, TLS expiry, cron results, containers, error counts, memory) through the site's own
  SMTP account; credentials are read at run time from a root-only file that is not published. Since
  2026-10-03 it also checks the nginx :443/:80 listeners, every nginx-loaded config file against the private
  config-backup repo, pending security updates and updates skipped over edited config files, that Plesk's
  own nginx package stays uninstalled (apt pin), Let's Encrypt renewal errors and renewed-but-unserved
  certificates; `--label` marks an extra run, and it stays silent under cron when the mail was sent.
- (2026-10) **Logo:** the Lichess knight is replaced everywhere it appeared —
  favicons, Safari mask icon (removed), Open Graph image, web-app manifest
  (`public/static/prcoffee/manifest.json`: name "Chess Puerto Rico Coffee",
  short_name "Chess PR Coffee"), apple-touch icon, JSON-LD logo, the header
  icon and the puzzle Zen-mode home button — by the Chess Puerto Rico Coffee
  coffee-bean pawn. The logo files in `public/static/prcoffee/`
  (`logo-512.png`, `favicon-*.png`, `favicon.ico`, `apple-touch-icon.png`) are
  this site's own original artwork, included so the deployment source is
  complete; they are not part of upstream Lichess.

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
- (2026-10) **picfit** (image uploads/thumbnails; `docker/compose.yml`,
  `docker/conf/picfit.json.example`): host port publication removed (picfit is
  reached only over the internal Docker network) and `restart: unless-stopped`
  added; request signing enabled — picfit `secret_key` and lila
  `memo.picfit.secretKey` set to the same private value, replacing the public
  upstream default, so unsigned or forged `/display` requests (including remote
  `url=` fetches) are rejected; picfit debug mode off.
- (2026-10) **MongoDB** (`docker/compose.yml`): `ulimits nofile 64000` (the default
  1024 crashed mongod during a puzzle-path rebuild with "Too many open files") and a
  60-second healthcheck interval (5 s while starting) to cut log noise.
- (2026-10) **Search ingestor** (`docker/compose-search.yml`): `INGESTOR_GAME_START_AT=0`
  removed for the running ingestor — it overrides the saved resume position and fails
  with `ChangeStreamHistoryLost` once the oplog has rotated.
- (2026-10) **picfit**: `enable_delete` turned on, so lila's image deletes take effect.
- (2026-10) **lila_push** VAPID subject changed to the site's own address
  (`docker/compose.yml`); MongoDB healthcheck script `docker/scripts/replica-set.js`
  enables mongod `quiet` mode.
- (2026-10) **Prebuilt applications** (`docker/compose.yml`): lila and lila-fishnet no longer run
  through `sbt run`. They are packaged with sbt-native-packager (`stage`) by two one-off build services
  (`lila_build`, `lila_fishnet_build`, compose profile `build`), copied to `prebuilt/<app>/builds/<time>-<commit>/`
  with `current` / `prev` symlinks, and the containers start `/opt/prebuilt/current/bin/<app>` (mounted
  read-only). Same code, configuration file, JVM options and (dev) mode as before; the 2 GB heap from
  `build.sbt` is now passed in `JAVA_OPTS`, because `run / javaOptions` do not reach a staged app, and
  `-Duser.dir=/lila` keeps lila's relative paths (`public/`, `logs/`). This removes the resident sbt
  server JVMs (~5 GB of RAM). lila's build packages `conf/` into its jar, so the build service mounts
  the secret-free `docker/conf/lila.build.conf` as `conf/application.conf`; the running app reads the
  real configuration through `-Dconfig.file`.
- (2026-10) **Video library kill switch** (`docker/conf/lila.conf.example`): `video.sheet.url` points
  at an unreachable local address. lila's video sheet sync (scheduled in prod mode, or run from the
  admin command line) deletes every video that is not in lichess.org's spreadsheet; a failed fetch
  stops it before anything is deleted, so this site's own curated library is never replaced.

## 3. Custom utilities

- **puzzle-import/import_puzzles.py**: Standalone Python script
  (no lila code imports) that parses the public Lichess puzzle CSV
  dataset and loads it into the local MongoDB in the schema expected
  by lila's puzzle reader.
- **puzzle-import/import_puzzles.py** (2026-10): `--upsert` mode added. Note: a full
  import is not usable on its own — lila's puzzle page needs each puzzle's source game
  in the local database (`GameJson.scala`), which a CSV import does not provide; the
  2026-10 attempt was rolled back for that reason.
- **ops/chess-puzzle-regen-paths.sh** (2026-10): wrapper for upstream's
  `cron/mongodb-puzzle-regen-paths.js` (lock, logging, fails loudly); its cron entry is
  included but not installed while only the seed puzzle set is loaded.
- **ops/** (2026-10): deployment scripts and units — daily-puzzle recycling
  (`chess-recycle-daily-puzzles.sh` + cron), nightly MongoDB dump with read-back
  verification (`chess-mongodump.sh` + cron), and the contact-form service unit
  with its SMTP drop-in. E-mail addresses are sanitized.
- **ops/chess-auto-feed.sh** (2026-10): keeps the homepage news feed (`daily_feed`)
  current — twice a week (cron included) it posts one item built only from real data
  through a fixed template: the top 1–2 official broadcasts of the week from
  lichess.org's public API (one request per run, identified User-Agent, no personal
  names), the site's own game/tournament/new-player counts, and the next scheduled
  tournament. It skips runs with nothing new, never deletes posts (older ones are set
  non-public), and backs up the collection before every write. Game ids listed in an
  optional local file (test games played on the live site) are left out of the counts.
- **ops/chess-boot-heal.sh** + **ops/chess-boot-heal.service** (2026-10): after Docker
  starts, checks that lila-ws, lila-fishnet and lila each subscribed to their Redis
  channel and restarts (once) a lila-ws or lila-fishnet container that never connected.
  Docker restarts all containers in parallel at boot; lila-ws once lost the race to
  resolve the Redis host, and its JVM stayed running with a dead main thread, so no
  WebSocket worked. lila itself is restarted too (grace 300 s) when it runs as a prebuilt app;
  under `sbt run` (slow cold compile) it is only reported, never restarted.
- **ops/chess-rebuild-lila.sh** (2026-10): rebuilds the prebuilt lila or lila-fishnet after a code
  change — builds in the one-off container while the site keeps running, copies the result to a new
  `prebuilt/<app>/builds/…` folder, switches `current`, restarts only that service, verifies it
  (Redis subscription, homepage, one game against the computer) and switches back by itself if the new
  build does not come up; `--rollback` and `--status` options.
- **ops/chess-ai-game-test.py** (2026-10): end-to-end test of play against the
  computer — creates an anonymous game through the normal setup form, plays it over
  the same WebSocket a browser uses, waits for the engine's move and aborts the game.
  Standard library only.
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

- `javaOptions` heap of the forked application JVM: `-Xmx512m` → `-Xmx2g`. (Since 2026-10-08 the
  app runs prebuilt and gets the same heap from `JAVA_OPTS` in `docker/compose.yml`; this line only
  matters for `sbt run`.)

### modules/pref/src/main/Pref.scala (2026-10)

- Default background for visitors who are not logged in: `Bg.SYSTEM` → `Bg.DARK`.
  Upstream changed this default from dark to "follow the device theme" in 2026; this site's
  branding is designed for the dark theme. Account holders keep upstream's default.

Each file is in `lila-modifications/` with an `.upstream.diff` generated with
`git diff` against the deployed upstream lila commit (`f5b261e`, deployed 2026-10-08;
previously `f9e0e4c`). The same four files carry the only source changes.

## Upstream versions

The deployment tracks the upstream Lichess repositories directly from
github.com/lichess-org. For the exact upstream commit currently deployed,
consult the docker-compose image tags in `docker/compose.yml`.

Deployed since 2026-10-08: lila `f5b261e` (+ the modifications above), lila-ws image pinned by
digest in `docker/compose-lila-ws-image.yml`, lila-fishnet `3837bbc`, fishnet `2.15.0`, lila-docker
upstream `f1e918c` merged with this site's compose changes (`docker/*.upstream.diff`).

---

*Last updated: October 2026*
