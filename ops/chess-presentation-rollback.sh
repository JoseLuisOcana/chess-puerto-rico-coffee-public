#!/bin/bash
# chess-presentation-rollback.sh — undo the 2026-10-08 "presentation polish" of chesspuertoricocoffee.com in one command
# (own FAQ page, Spanish About/FAQ/Contact, ?lang= switch, Spanish branding rules, bilingual sponsor/AGPL/13+ texts).
#
# Restores, byte for byte, the 9 files changed that day from /root/presentation-20261008/ (taken right before), moves the
# NEW pages (httpdocs/faq.html, httpdocs/es/) aside into a snapshot folder — nothing is deleted — then `nginx -t` and a
# graceful reload (never a restart). If `nginx -t` fails, everything is put back as it was and nginx is NOT reloaded.
# /etc/nginx/conf.d/chess-lang-map.conf is left in place: it only defines maps, unused once the old vhost is back.
# Afterwards /faq is lila's own page again and the site is English/lila-Spanish as before 2026-10-08.
#
# Usage: sudo /usr/local/sbin/chess-presentation-rollback.sh            # restore + reload
#        sudo /usr/local/sbin/chess-presentation-rollback.sh --dry-run  # show what would change, change nothing
# Log:   /var/log/chess-presentation-rollback.log
# The weekly health report will then warn that loaded nginx files differ from server-config-backup: expected after a
# rollback (commit the restored files, or re-apply from the snapshot folder this script prints).

set -uo pipefail

BACKUP=/root/presentation-20261008
H=/var/www/vhosts/chesspuertoricocoffee.com/httpdocs
LOG=/var/log/chess-presentation-rollback.log
DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true

# backup copy (relative to $BACKUP) : live file
FILES=(
  "nginx/chesspuertoricocoffee.com.conf:/etc/nginx/plesk.conf.d/vhosts/chesspuertoricocoffee.com.conf"
  "nginx/chess-branding.conf:/etc/nginx/snippets/chess-branding.conf"
  "nginx/vhost_nginx.conf.prestaging:/var/www/vhosts/system/chesspuertoricocoffee.com/conf/vhost_nginx.conf"
  "httpdocs/about.html:$H/about.html"
  "httpdocs/contact-us.html:$H/contact-us.html"
  "httpdocs/prcoffee/branding.css:$H/prcoffee/branding.css"
  "httpdocs/prcoffee/signup.js:$H/prcoffee/signup.js"
  "httpdocs/prcoffee/videos.js:$H/prcoffee/videos.js"
  "seo-files/sitemap.xml:/var/www/vhosts/chesspuertoricocoffee.com/seo-files/sitemap.xml"
)
NEW=("$H/faq.html" "$H/es")   # created 2026-10-08; moved aside, not deleted

say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }

if [[ $EUID -ne 0 ]]; then echo "run as root: sudo $0" >&2; exit 1; fi
for e in "${FILES[@]}"; do
  [[ -s "$BACKUP/${e%%:*}" ]] || { say "ERROR backup copy missing: $BACKUP/${e%%:*}"; exit 1; }
  [[ -f "${e#*:}" && ! -L "${e#*:}" ]] || { say "ERROR live file missing or a symlink: ${e#*:}"; exit 1; }
done

changed=0
for e in "${FILES[@]}"; do
  src="$BACKUP/${e%%:*}"; dst="${e#*:}"
  if cmp -s "$src" "$dst"; then $DRY && say "same          $dst"; continue; fi
  changed=$((changed + 1))
  $DRY && say "would restore $dst ($(diff "$src" "$dst" | grep -c '^[<>]') changed lines)"
done
for n in "${NEW[@]}"; do [[ -e "$n" ]] && { changed=$((changed + 1)); $DRY && say "would move aside $n"; }; done
if $DRY; then say "dry-run: $changed change(s) would be made; nothing changed"; exit 0; fi
if [[ $changed -eq 0 ]]; then say "nothing to do: already rolled back"; exit 0; fi

SNAP=/root/presentation-rollback-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$SNAP" && chmod 700 "$SNAP" || { say "ERROR cannot create $SNAP"; exit 1; }
for e in "${FILES[@]}"; do
  dst="${e#*:}"; mkdir -p "$SNAP$(dirname "$dst")" && cp -p "$dst" "$SNAP$dst" || { say "ERROR snapshot of $dst failed — nothing changed"; exit 1; }
done
say "snapshot of the current (presentation) state: $SNAP"

undo() {   # put the presentation state back exactly as it was
  for e in "${FILES[@]}"; do dst="${e#*:}"; cp -p "$SNAP$dst" "$dst"; done
  for n in "${NEW[@]}"; do [[ -e "$SNAP$n" && ! -e "$n" ]] && mv "$SNAP$n" "$n"; done
}

for e in "${FILES[@]}"; do
  src="$BACKUP/${e%%:*}"; dst="${e#*:}"
  cmp -s "$src" "$dst" && continue
  cp -p "$src" "$dst" && say "restored      $dst" || { say "ERROR restoring $dst — undoing"; undo; exit 1; }
done
for n in "${NEW[@]}"; do
  [[ -e "$n" ]] || continue
  mkdir -p "$SNAP$(dirname "$n")" && mv "$n" "$SNAP$n" && say "moved aside   $n -> $SNAP$n" || { say "ERROR moving $n — undoing"; undo; exit 1; }
done

if ! nginx -t >>"$LOG" 2>&1; then
  say "ERROR nginx -t failed after the restore — put everything back, nginx NOT reloaded (old workers still serving). See $LOG"
  undo
  nginx -t >>"$LOG" 2>&1 && say "presentation state back; nginx -t OK" || say "ERROR nginx -t still fails — do NOT reload; see $LOG"
  exit 1
fi
systemctl reload nginx && sleep 3   # let the old workers finish before checking

fail=0
chk() {   # chk <path> <expected status> [file whose bytes the body must equal]
  local out code
  out=$(mktemp)
  code=$(curl -s -o "$out" --max-time 20 --resolve chesspuertoricocoffee.com:443:82.165.212.204 \
         -H 'Accept-Language: en-US,en;q=0.9' -w '%{http_code}' "https://chesspuertoricocoffee.com$1")
  if [[ "$code" != "$2" ]] || { [[ -n "${3:-}" ]] && ! cmp -s "$out" "$3"; }; then
    say "CHECK FAIL $1 -> $code (want $2${3:+, body = $3})"; fail=1
  else
    say "check ok   $1 -> $code"
  fi
  rm -f "$out"
}
chk / 200
chk /about 200 "$BACKUP/httpdocs/about.html"
chk /faq 200
chk /signup 200
chk /prcoffee/branding.css 200 "$BACKUP/httpdocs/prcoffee/branding.css"
if [[ $fail -eq 0 ]]; then say "ROLLBACK OK — site is as before 2026-10-08's presentation changes. Snapshot: $SNAP"; exit 0; fi
say "ROLLBACK DONE BUT A CHECK FAILED — see above. Snapshot (to go forward again): $SNAP"; exit 2
