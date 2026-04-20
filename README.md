# Chess Puerto Rico Coffee — Deployment Source

A community chess server for Puerto Rico, sponsored by
[PuertoRicoCoffeeShop.com](https://www.puertoricocoffeeshop.com)
and operated at [chesspuertoricocoffee.com](https://chesspuertoricocoffee.com).

This is a **modified deployment of [Lichess](https://lichess.org)**
(the `lila` codebase and its associated services).

## Why this repository exists

[Lichess](https://github.com/lichess-org/lila) is licensed under the
[GNU Affero General Public License v3.0 (AGPL-3.0)](./LICENSE). Under the
AGPL-3.0 network clause, any user who interacts with a modified version of
the software over a network is entitled to the complete corresponding
source code of the running version.

This repository contains all modifications made to upstream Lichess for the
Chess Puerto Rico Coffee deployment — configuration files, custom nginx
configs, branding injection, custom scripts, and documentation — so that
anyone using chesspuertoricocoffee.com can obtain the source as required
by AGPL-3.0.

## What's in this repository

| Path | Contents |
|---|---|
| `lila-modifications/` | Direct modifications to upstream lila Scala source code, mirroring the upstream directory structure |
| `caddy/` | Modified Caddyfile with case-insensitive WebSocket matcher |
| `docker/` | docker-compose overrides, sanitized .env example, sanitized lila.conf.example |
| `nginx/` | Custom nginx configs (Plesk vhost + parallel system config, plus the branding sub_filter snippet) |
| `public/static/` | Custom static pages (about, privacy, terms, contact) |
| `public/` | Custom robots.txt and sitemap.xml |
| `puzzle-import/` | Standalone Python utility to import the public Lichess puzzle database into MongoDB |
| `LICENSE` | Full AGPL-3.0 license text |
| `COPYRIGHT` | Copyright and upstream attribution |
| `NOTICE.md` | Detailed list of modifications from upstream |

## What's NOT in this repository

- **Upstream Lichess source code** — unmodified, available directly from
  [github.com/lichess-org](https://github.com/lichess-org)
- **Secrets** — all API keys, database passwords, OAuth tokens, and SMTP
  credentials are excluded. See `.env.example` and `lila.conf.example` for
  templates
- **Large data files** — the Lichess puzzle CSV (~1 GB) is not included;
  `puzzle-import/README.md` explains where to download it

## Deployment environment

- Ubuntu 22.04 on IONOS VPS
- Plesk Obsidian 18.x for domain management
- Docker Compose orchestration via lila-docker
- Active profiles: base, stockfish-play, stockfish-analysis, search, gifs, external-engine, push, thumbnails, email

## License

This project and all modifications it contains are licensed under
**AGPL-3.0**, the same license as upstream Lichess. See [LICENSE](./LICENSE)
and [COPYRIGHT](./COPYRIGHT).

## Upstream attribution

Chess Puerto Rico Coffee would not exist without the work of the Lichess
team and thousands of volunteer contributors. We are deeply grateful for
their gift to the chess world.

- **Lichess:** https://lichess.org — https://github.com/lichess-org/lila
- **Stockfish:** https://stockfishchess.org

## Contact

For questions about this deployment: **system@chesspuertoricocoffee.com**

For upstream Lichess issues or contributions, please use the
[upstream repositories](https://github.com/lichess-org).

## Sponsor

[PuertoRicoCoffeeShop.com](https://www.puertoricocoffeeshop.com) — sharing
authentic Puerto Rican coffee with the world.
