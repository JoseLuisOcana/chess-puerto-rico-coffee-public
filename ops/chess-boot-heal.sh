#!/bin/bash
# chess-boot-heal.sh — after Docker starts, make sure the chess containers that talk to Redis really connected,
# and restart one that did not. Run by chess-boot-heal.service (at boot and whenever docker.service restarts).
#
# Why (2026-10-08): after the pre-trip reboot, "Play with the computer" — and every WebSocket: lobby, games, TV —
# was dead. dockerd restarts all containers in parallel at boot. lila_ws joined lila-network at 17:29:25Z, failed to
# resolve 'redis' at 17:29:31Z (Docker DNS SERVFAIL: redis was not on the network yet) and redis joined at 17:29:32Z.
# lila_ws connects to Redis once, in a static initializer: its main thread died (ExceptionInInitializerError) but the
# JVM's other threads kept the process alive, so the container stayed "Up", the restart policy never fired, port 9664
# stayed closed and nginx answered 502 on every socket. compose depends_on cannot help (dockerd, not compose, starts
# containers at boot) and Docker never restarts an "unhealthy" container — hence this script.
#
# Health = a Redis subscriber on the channel only that service subscribes to:
#   lila_ws      -> site-out     restart   (normally subscribed ~6 s after start)
#   lila_fishnet -> fishnet-out  restart   (prebuilt app: subscribed ~2 s after start; grace 180 s)
#   lila         -> site-in      restart   (prebuilt app: serving ~15 s after start; grace 300 s)
# Since 2026-10-08 both run PREBUILT apps (sbt-native-packager stage, see CLAUDE.md "Rebuild lila"), so a restart is
# cheap. If one is back on `sbt run` (rollback mode), the old rules apply automatically: lila_fishnet grace 600 s, and
# lila REPORT ONLY — never restarted here, because a cold sbt compile can take > 10 min.
# A container still inside its grace period is waited for, not restarted — except lila_ws whose log already shows the
# fatal 'Exception in thread "main"' since it started. A container that is not running (stopped on purpose?) is
# reported, never started. At most one restart per service per run.
#
# --dry-run: report only, restart nothing. Log: /var/log/chess-boot-heal.log (and the journal).
# Exit 0 = every subscriber present (possibly after a restart). Test hook: CHESS_HEAL_CHECKS="svc:chan:grace:action …".
set -u
LOG=/var/log/chess-boot-heal.log
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
REDIS=lila-docker-redis-1
problems=0

log() { local m; m="$(date '+%F %T %Z') $*"; echo "$m"; echo "$m" >> "$LOG"; }
rcli() { timeout 10 docker exec "$REDIS" redis-cli "$@" 2>/dev/null; }
subs() { rcli PUBSUB NUMSUB "$1" | sed -n 2p; }
started() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null; }
age() { local s; s=$(started "$1") || return 1; echo $(( $(date +%s) - $(date -d "$s" +%s) )); }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
main_died() { docker logs --since "$(started "$1")" "$1" 2>&1 | grep -q 'Exception in thread "main"'; }

# 0 = subscribed; 1 = grace over (or fatal main-thread exception); 2 = container stopped
wait_sub() {
    local c=$1 ch=$2 grace=$3 n a
    while :; do
        n=$(subs "$ch"); [ "${n:-0}" -ge 1 ] 2>/dev/null && return 0
        running "$c" || return 2
        a=$(age "$c") || return 2
        [ "$a" -ge "$grace" ] && return 1
        [ "$a" -ge 15 ] && main_died "$c" && return 1
        sleep 5
    done
}

[ $DRY = 1 ] && log "start (dry run)" || log "start"
for i in $(seq 1 60); do [ "$(rcli PING)" = PONG ] && break; sleep 5; done
if [ "$(rcli PING)" != PONG ]; then
    log "FAIL redis ($REDIS) not answering PING after 5 min — nothing checked"
    exit 1
fi

# prebuilt app (2026-10-08) -> cheap restart; sbt (rollback mode) -> the old, cautious rules. Decided once Docker answers.
prebuilt() { docker inspect -f '{{json .Config.Entrypoint}}' "lila-docker-$1-1" 2>/dev/null | grep -q '"/opt/prebuilt/current/bin/'; }
if prebuilt lila_fishnet; then FISH="lila_fishnet:fishnet-out:180:restart"; else FISH="lila_fishnet:fishnet-out:600:restart"; fi
if prebuilt lila; then LILA="lila:site-in:300:restart"; else LILA="lila:site-in:900:report"; fi
CHECKS=${CHESS_HEAL_CHECKS:-"lila_ws:site-out:90:restart $FISH $LILA"}

for chk in $CHECKS; do
    IFS=: read -r svc ch grace action <<< "$chk"
    c="lila-docker-$svc-1"
    if ! docker inspect "$c" >/dev/null 2>&1; then log "FAIL $svc: container $c does not exist"; problems=$((problems+1)); continue; fi
    if ! running "$c"; then log "WARN $svc: $c is not running (stopped on purpose?) — not started"; problems=$((problems+1)); continue; fi
    wait_sub "$c" "$ch" "$grace"; r=$?
    if [ $r = 0 ]; then log "OK   $svc: subscribed to $ch (container up $(age "$c")s)"; continue; fi
    if [ $r = 2 ]; then log "FAIL $svc: $c stopped while waiting"; problems=$((problems+1)); continue; fi
    why="no subscriber on $ch after $(age "$c")s up"; main_died "$c" && why="$why, log shows 'Exception in thread \"main\"'"
    if [ "$action" != restart ]; then
        log "WARN $svc: $why — NOT restarted automatically (look: docker logs --tail 80 $c)"
        problems=$((problems+1)); continue
    fi
    if [ $DRY = 1 ]; then log "DRY  $svc: $why — would run: docker restart $c"; problems=$((problems+1)); continue; fi
    log "HEAL $svc: $why — docker restart $c"
    docker logs --since "$(started "$c")" "$c" 2>&1 | grep -m3 -E '^(Exception|Caused by)' | cut -c1-200 \
        | while IFS= read -r l; do log "       $l"; done
    if ! timeout 120 docker restart "$c" >/dev/null 2>&1; then log "FAIL $svc: docker restart $c failed"; problems=$((problems+1)); continue; fi
    wait_sub "$c" "$ch" "$grace"; r=$?
    if [ $r = 0 ]; then log "OK   $svc: healed — subscribed to $ch $(age "$c")s after the restart"
    else log "FAIL $svc: still no subscriber on $ch after the restart (docker logs --tail 80 $c)"; problems=$((problems+1)); fi
done

[ $problems = 0 ] && log "done: all chess Redis subscribers present" || log "done: $problems problem(s)"
exit $(( problems > 0 ))
