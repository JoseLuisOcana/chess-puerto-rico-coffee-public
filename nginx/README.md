# nginx configuration for chesspuertoricocoffee.com

Updated 2026-10. Loaded on the server (verify with `nginx -T`):

| File in this repo | Deployed as |
|---|---|
| `plesk-vhosts-chesspuertoricocoffee.com.conf` | `/etc/nginx/plesk.conf.d/vhosts/chesspuertoricocoffee.com.conf` (the live vhost) |
| `snippets-chess-branding.conf` | `/etc/nginx/snippets/chess-branding.conf` (branding sub_filters, headers, bot block) |
| `snippets-dotfile-deny.conf` | `/etc/nginx/snippets/dotfile-deny.conf` |
| `conf.d/chess-ratelimit.conf` | `/etc/nginx/conf.d/chess-ratelimit.conf` (crawler maps + limit_req zone) |
| `conf.d/chess-noindex-map.conf` | `/etc/nginx/conf.d/chess-noindex-map.conf` |
| `conf.d/connection-upgrade-map.conf` | `/etc/nginx/conf.d/connection-upgrade-map.conf` |

Not loaded: `vhost_nginx.conf.prestaging` is a mirror of the vhost's custom
directives kept in Plesk's `vhost_nginx.conf` hook for a possible future Plesk
nginx component install. It must never be `include`d alongside the live vhost
(duplicate `location` blocks are fatal).

The earlier note that Plesk's `/var/www/vhosts/system/<domain>/conf/nginx.conf`
is an identical copy no longer applies; that file is not loaded.

After editing: `sudo nginx -t && sudo systemctl reload nginx`.
