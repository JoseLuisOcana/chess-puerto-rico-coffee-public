#!/bin/bash
# chess-mongodump.sh — nightly logical backup of the chesspuertoricocoffee.com MongoDB
#
# Added 2026-10-02 (fix item 13, /opt/chess/lila-docker/fixes-2026-10-02.md).
#
# - Dumps every database except `local` (the oplog; mongodump skips it by default) from the lila-docker `mongodb` service
#   as one gzip archive: /var/backups/chess-mongo/chess-mongo-YYYYMMDD-HHMM.archive.gz
# - Writes to a .partial file and only renames it into place after a READ-BACK check:
#   gzip integrity + `mongorestore --dryRun` must list the same collections the live
#   `lichess` DB has. A dump that fails the check is kept as .FAILED and the script exits 1.
# - Keeps 14 days. Retention only ever matches this script's own filename pattern.
# - Logs one line per run to /var/log/chess-mongodump.log; errors go to stderr (cron mails).
#
# Restore (DESTRUCTIVE to whatever is in the target DB - read the archive name twice):
#   cd /opt/chess/lila-docker && sudo docker compose exec -T mongodb \
#     mongorestore --archive --gzip --drop < /var/backups/chess-mongo/<file>.archive.gz

set -euo pipefail

DIR=/var/backups/chess-mongo
LOG=/var/log/chess-mongodump.log
KEEP_DAYS=14
TS=$(date +%Y%m%d-%H%M)
OUT="$DIR/chess-mongo-$TS.archive.gz"
TMP="$OUT.partial"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
fail() { log "FAIL $*"; echo "chess-mongodump: FAIL $*" >&2; exit 1; }

install -d -m 700 "$DIR"
cd /opt/chess/lila-docker

docker compose exec -T mongodb mongodump --quiet --archive --gzip \
  > "$TMP" 2>>"$LOG" || fail "mongodump exited non-zero ($TMP kept)"

gzip -t "$TMP" 2>>"$LOG" || { mv "$TMP" "$OUT.FAILED"; fail "gzip integrity check failed: $OUT.FAILED"; }

live=$(docker compose exec -T mongodb mongosh --quiet lichess --eval \
  'print(db.getCollectionNames().filter(c => !c.startsWith("system.")).length)' | tr -d '\r')
inarch=$(docker compose exec -T mongodb mongorestore --dryRun --archive --gzip -v < "$TMP" 2>&1 \
  | grep -oE 'found collection lichess\.[^ ]+ bson' | grep -v 'lichess\.system\.' | sort -u | wc -l)
[[ "$live" =~ ^[0-9]+$ && "$live" -gt 0 && "$inarch" -eq "$live" ]] \
  || { mv "$TMP" "$OUT.FAILED"; fail "read-back mismatch: live lichess collections=$live, in archive=$inarch ($OUT.FAILED)"; }

mv "$TMP" "$OUT"
chmod 600 "$OUT"

deleted=$(find "$DIR" -maxdepth 1 -type f -name 'chess-mongo-*.archive.gz' -mtime +$((KEEP_DAYS - 1)) -print -delete | wc -l)

log "OK $OUT size=$(stat -c %s "$OUT") lichess_collections=$live verified=yes pruned=$deleted"
