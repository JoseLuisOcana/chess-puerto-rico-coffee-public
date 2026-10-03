#!/bin/bash
# chess-puzzle-regen-paths.sh — rebuild lila's puzzle paths (lichess.puzzle2_path) from puzzle2_puzzle.
#
# Added 2026-10-02 with the full Lichess puzzle import (fixes log: /opt/chess/lila-docker/fixes-2026-10-02.md).
# Runs upstream's repos/lila/cron/mongodb-puzzle-regen-paths.js inside the mongodb container (/lila is bind-
# mounted there). That script builds a new `gen` theme by theme into puzzle2_path_next, $merges it into
# puzzle2_path and deletes the old generation — lila keeps serving puzzles throughout.
# Upstream: "NOT OK to run concurrently" -> flock. It prints ONLY when a theme is "buggy", and then keeps the
# old generation instead of deleting it, so any output or >1 remaining gen is treated as a FAILURE (exit 1,
# cron mails). lila logs "paths appear to be stale" if the newest gen is > 1 day old (prod mode only).
set -uo pipefail
LOG=/var/log/chess-puzzle-regen-paths.log
log(){ echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
exec 9>/run/lock/chess-puzzle-regen-paths.lock
flock -n 9 || { log "SKIP previous run still active"; exit 0; }
cd /opt/chess/lila-docker || { log "FAIL cd"; exit 1; }
start=$(date +%s)
# upstream note: may need internalQueryMaxPushBytes 300MB ($push of large rating buckets)
docker compose exec -T mongodb mongosh --quiet --eval 'db.adminCommand({setParameter:1, internalQueryMaxPushBytes:314572800}).ok' >/dev/null 2>&1
out=$(docker compose exec -T mongodb mongosh --quiet lichess /lila/cron/mongodb-puzzle-regen-paths.js 2>&1); rc=$?
res=$(docker compose exec -T mongodb mongosh --quiet lichess --eval 'const g=db.puzzle2_path.distinct("gen"); print(db.puzzle2_path.estimatedDocumentCount()+" "+g.length+" "+new Date(Math.max(...g)).toISOString())' 2>&1 | tr -d '\r')
read -r paths gens newest <<< "$res"
el=$(( $(date +%s) - start ))
if [ $rc -ne 0 ] || [ -n "$out" ] || [ "${gens:-0}" != "1" ]; then
  log "FAIL rc=$rc ${el}s paths=${paths:-?} gens=${gens:-?} newest=${newest:-?} output: $(echo "$out" | head -5 | tr '\n' ' ')"
  echo "chess-puzzle-regen-paths: FAIL (see $LOG)" >&2; exit 1
fi
log "OK ${el}s paths=$paths gens=$gens newest=$newest"
