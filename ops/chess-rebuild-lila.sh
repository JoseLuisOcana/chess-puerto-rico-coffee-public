#!/bin/bash
# chess-rebuild-lila.sh — rebuild the PREBUILT lila or lila-fishnet after a code change, with a safe swap (2026-10-08).
#
# Since 2026-10-08 lila and lila-fishnet run from prebuilt apps (sbt-native-packager `stage`), not `sbt run`, so a code
# change in repos/lila or repos/lila-fishnet does NOTHING until it is rebuilt. Layout (lila-docker/prebuilt/, not in git):
#   prebuilt/<app>/builds/<UTC time>-<commit>/   one complete app per build (bin/, lib/, BUILD-INFO)
#   prebuilt/<app>/current -> builds/…            what the container starts (/opt/prebuilt/current/bin/<app>, read-only)
#   prebuilt/<app>/prev    -> builds/…            the build before it (for --rollback)
# The start script resolves symlinks, so a RUNNING app keeps using its own builds/… folder; a swap only affects the
# next start. sbt itself only ever writes its own stage folder inside the repo (target/universal/stage), which the
# running app never uses: sbt's stage task deletes what it staged last time, and `sbt clean` wipes target/.
#
# Steps: 1. build with the one-off `lila_build` / `lila_fishnet_build` container (compose profile "build") — the site
#           stays up meanwhile; a failed build changes nothing;
#        2. copy the stage folder to a new builds/… folder, write BUILD-INFO (commit, date, uncommitted edits);
#        3. point current at it (prev = the old one) and restart ONLY that service;
#        4. verify (Redis subscriber; lila also homepage 200) within 5 min — if not, point current back at the old
#           build and restart again by itself (exit 1);
#        5. lila only: play a real game against the computer (reported; never rolled back on);
#        6. delete builds that are neither current, prev nor in use by the running container.
#
# Usage: sudo chess-rebuild-lila.sh [lila|fishnet] [--no-restart | --rollback | --status]
#   lila (default) / fishnet   which app
#   --no-restart               build + point current at it, no restart (later: cd /opt/chess/lila-docker && docker compose restart lila)
#   --rollback                 swap current and prev, restart, verify (undo the last rebuild)
#   --status                   show current / prev / running build, change nothing
# Env (tests): PROJECT (default /opt/chess/lila-docker), CHESS_REBUILD_LOG (default /var/log/chess-rebuild-lila.log),
#   PROBE_URL (default http://127.0.0.1:8080/ = caddy), AI_TEST (default /usr/local/bin/chess-ai-game-test.py; "" = skip)
# UI (JS/CSS) changes are separate: cd /opt/chess/lila-docker && docker compose run --rm ui /lila/ui/build --debug
set -euo pipefail
PROJECT=${PROJECT:-/opt/chess/lila-docker}; WHAT=lila; MODE=build
for a in "$@"; do case "$a" in lila|fishnet) WHAT=$a;; --no-restart) MODE=norestart;; --rollback) MODE=rollback;; --status) MODE=status;;
  *) echo "usage: $0 [lila|fishnet] [--no-restart | --rollback | --status]"; exit 2;; esac; done
LOG=${CHESS_REBUILD_LOG:-/var/log/chess-rebuild-lila.log}
PROBE_URL=${PROBE_URL:-http://127.0.0.1:8080/}
AI_TEST=${AI_TEST-/usr/local/bin/chess-ai-game-test.py}
log() { echo "$(date '+%F %T %Z') [$WHAT] $*" | tee -a "$LOG"; }
die() { log "FAIL $*"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
if [ "$WHAT" = lila ]; then
  REPO=$PROJECT/repos/lila; STAGE=$REPO/target/universal/stage; SVC=lila; BUILD=lila_build; NAME=lila; CHAN=site-in
else
  REPO=$PROJECT/repos/lila-fishnet; STAGE=$REPO/app/target/universal/stage; SVC=lila_fishnet; BUILD=lila_fishnet_build; NAME=lila-fishnet; CHAN=fishnet-out
fi
P=$PROJECT/prebuilt/$NAME
cd "$PROJECT"
REDIS=$(docker compose ps -q redis); [ -n "$REDIS" ] || die "redis container not found in $PROJECT"

target() { readlink "$P/$1" 2>/dev/null || true; }                       # builds/<x> or ""
setlink() { ln -sfn "$2" "$P/.$1.tmp" && mv -T "$P/.$1.tmp" "$P/$1"; }   # atomic symlink replace
running_build() {   # the builds/<x> folder the service's java process was started from ("" if none)
  local c pid; c=$(docker compose ps -q "$SVC"); [ -n "$c" ] || return 0
  pid=$(docker inspect -f '{{.State.Pid}}' "$c"); [ "${pid:-0}" -gt 0 ] || return 0
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -o 'builds/[^/]*' | head -1 || true
}
up() {   # 0 when the service is subscribed in Redis (and lila's homepage answers 200), within 5 min
  local n c
  for i in $(seq 1 60); do
    n=$(docker exec "$REDIS" redis-cli PUBSUB NUMSUB "$CHAN" | sed -n 2p)
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
      [ "$SVC" != lila ] && { log "OK $SVC subscribed to $CHAN"; return 0; }
      c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'Host: chesspuertoricocoffee.com' -H 'X-Forwarded-Proto: https' "$PROBE_URL" || true)
      [ "$c" = 200 ] && { log "OK $SVC subscribed to $CHAN, homepage 200"; return 0; }
    fi
    sleep 5
  done
  return 1
}
restart() { log "restarting $SVC on $(target current)"; docker compose restart "$SVC" >/dev/null 2>&1; sleep 5; up; }

if [ "$MODE" = status ]; then
  echo "current: $(target current)"; echo "prev:    $(target prev)"; echo "running: $(running_build)"
  echo "builds:  $(ls "$P/builds" 2>/dev/null | tr '\n' ' ')"; cat "$P/current/BUILD-INFO" 2>/dev/null; exit 0
fi
exec 9>"/run/lock/chess-rebuild-lila-$(echo "$PROJECT" | md5sum | cut -c1-8).lock"
flock -n 9 || die "another rebuild is running for $PROJECT"

if [ "$MODE" = rollback ]; then
  cur=$(target current); prv=$(target prev)
  [ -n "$prv" ] && [ -x "$P/$prv/bin/$NAME" ] || die "no previous build (prev) in $P"
  setlink current "$prv"; setlink prev "$cur"
  log "ROLLBACK: current -> $prv (was $cur)"
  restart || die "$SVC did not come back after the rollback — look: docker compose logs --tail 80 $SVC"
  exit 0
fi

log "building $NAME from $(git -c safe.directory='*' -C "$REPO" log -1 --format='%h %s' | cut -c1-70) ..."
t0=$(date +%s)
docker compose run --rm --no-deps "$BUILD" >> "$LOG" 2>&1 || die "build failed (nothing changed; see $LOG)"
[ -x "$STAGE/bin/$NAME" ] && [ -n "$(ls "$STAGE/lib" 2>/dev/null)" ] || die "build produced no $STAGE/bin/$NAME (nothing changed)"
commit=$(git -c safe.directory='*' -C "$REPO" rev-parse HEAD)
new=builds/$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:7}
mkdir -p "$P/builds"; cp -a "$STAGE" "$P/$new"
{ echo "commit=$commit"; echo "built=$(date -u +%FT%TZ)";
  echo "dirty=$(git --no-optional-locks -c safe.directory='*' -C "$REPO" status --porcelain --untracked-files=no | wc -l)"; } > "$P/$new/BUILD-INFO"
[ -x "$P/$new/bin/$NAME" ] || die "copy to $P/$new failed (nothing changed)"
log "build OK in $(( $(date +%s) - t0 )) s -> $new ($(ls "$P/$new/lib" | wc -l) jars)"
old=$(target current)
setlink current "$new"; [ -n "$old" ] && setlink prev "$old"
if [ "$MODE" = norestart ]; then
  log "current -> $new; NOT restarted (--no-restart); undo: $0 $WHAT --rollback"
else
  if ! restart; then
    log "FAIL the new build did not come up within 5 min — going back to $old"
    [ -n "$old" ] || die "no previous build to go back to — look: docker compose logs --tail 80 $SVC"
    setlink current "$old"; setlink prev "$new"
    restart && die "new build rejected; the PREVIOUS build ($old) is running again (rejected one kept as prev)"
    die "previous build did not come back either — look: docker compose logs --tail 80 $SVC; PANIC-BUTTONS 'Rebuild lila'"
  fi
  if [ "$SVC" = lila ] && [ -n "$AI_TEST" ] && [ -x "$AI_TEST" ]; then
    sleep 20   # let the fishnet clients settle after lila's restart
    if "$AI_TEST" >> "$LOG" 2>&1; then log "OK game against the computer"; else log "WARN game against the computer FAILED (see $LOG); undo: $0 $WHAT --rollback"; fi
  fi
fi
keep=" $(target current) $(target prev) $(running_build) "
for d in "$P"/builds/*/; do
  [ -d "$d" ] || continue
  b=builds/$(basename "$d"); [[ $b =~ ^builds/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7}$ ]] || continue
  case "$keep" in *" $b "*) continue;; esac
  rm -rf -- "$P/$b"; log "removed old build $b"
done
log "done: current=$(target current) prev=$(target prev) running=$(running_build)"
