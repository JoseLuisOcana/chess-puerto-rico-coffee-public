#!/bin/bash
# chess-search-rebuild.sh — check, or safely rebuild, the chess site's search indexes (2026-10-08).
#
# Search = Elasticsearch (container elasticsearch, volume lila-docker_es_data) filled from MongoDB by lila-search:
# the always-running lila_search_ingestor follows MongoDB's change streams; the one-off lila_search_ingestor_cli
# (compose profile utils) indexes everything from scratch. Five indexes: game, forum, team, ublog, study_with_chapters.
#
# Why this exists: the running ingestor NEVER creates an index. If one is missing, Elasticsearch used to auto-create it
# from the first document with guessed field types — that is how `game` ended up with its date as text (search counted
# games but could list none) while forum/team/study/ublog did not exist at all (2026-10-08). Since then the cluster
# setting action.auto_create_index forbids auto-creating those five names (a missing index now fails loudly), and only
# the CLI creates them, with lila-search's real mappings.
#
# Usage: sudo chess-search-rebuild.sh              CHECK only, changes nothing: indexes exist, green, real mappings,
#                                                  document counts = MongoDB, guard set, search containers up. Exit 0 = OK.
#        sudo chess-search-rebuild.sh --rebuild    backup, then rebuild all five indexes from MongoDB (~2 min; searches
#                                                  return little for ~1 min), then CHECK.
# Backup (--rebuild): verified mongodump (chess-mongodump.sh) + flushed copy of the Elasticsearch volume + index
#   settings/mappings, in /root/search-backups/<UTC time>/ (newest 3 kept). Restore the volume copy (only if a rebuild
#   ever went wrong — normally just rebuild again):
#     cd /opt/chess/lila-docker && sudo docker compose stop lila_search_ingestor lila_search_app elasticsearch
#     V=$(sudo docker volume inspect -f '{{.Mountpoint}}' lila-docker_es_data); sudo find "$V" -mindepth 1 -delete
#     sudo tar -C "$V" -xzf /root/search-backups/<time>/es_data-volume.tar.gz
#     sudo docker compose start elasticsearch && sleep 30 && sudo docker compose start lila_search_app lila_search_ingestor
# Log: /var/log/chess-search-rebuild.log
set -uo pipefail
PROJECT=/opt/chess/lila-docker; LOG=/var/log/chess-search-rebuild.log
INDEXES="game forum team ublog study_with_chapters"
GUARD="-game,-forum,-team,-study,-ublog,+*"
MODE=check; [ "${1:-}" = --rebuild ] && MODE=rebuild
[ $# -gt 0 ] && [ "$MODE" = check ] && { echo "usage: $0 [--rebuild]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
es() { docker exec lila-docker-elasticsearch-1 curl -s "$@"; }
cd "$PROJECT" || exit 1

check() {   # prints one line per check; exit status = number of problems (0 = all good)
  python3 -I - <<'PY'
import json, subprocess, sys
def es(path):
    r = subprocess.run(["docker", "exec", "lila-docker-elasticsearch-1", "curl", "-s", "localhost:9200" + path], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except ValueError: return {}
def mongo(js):
    r = subprocess.run(["docker", "exec", "lila-docker-mongodb-1", "mongosh", "--quiet", "lichess", "--eval", js], capture_output=True, text=True)
    return r.stdout.strip().split()[-1] if r.stdout.strip() else "?"
bad = 0
def line(ok, msg):
    global bad
    bad += 0 if ok else 1
    print(("OK   " if ok else "FAIL ") + msg)
h = es("/_cluster/health")
line(h.get("status") == "green", f"elasticsearch cluster health {h.get('status', 'NO ANSWER')}")
guard = (es("/_cluster/settings").get("persistent", {}).get("action", {}) or {}).get("auto_create_index", "")
line(all(f"-{n}" in guard for n in ("game", "forum", "team", "study", "ublog")), f"auto-create guard: {guard or 'MISSING'}")
# what lila-search indexes (lila-search 3.4.3 repos): games finished (s>=30), not imported (so!=7), with a player account
want = {"game": mongo('print(db.game5.countDocuments({s:{$gte:30}, so:{$ne:7}, us:{$exists:true}}))'),
        "forum": mongo('print(db.f_post.countDocuments({erasedAt:{$exists:false}}))'),
        "team": mongo('print(db.team.countDocuments({enabled:true}))'),
        "ublog": mongo('print(db.ublog_post.countDocuments({live:true, "automod.quality":{$ne:0}}))'),
        "study_with_chapters": mongo('print(db.study.countDocuments({}))')}
dates = {"game": "d", "forum": "da", "ublog": "date", "study_with_chapters": "createdAt", "team": None}
maps = es("/_mapping")
for i, w in want.items():
    if i not in maps:
        line(False, f"{i:20} index MISSING (sudo chess-search-rebuild.sh --rebuild)"); continue
    m = maps[i]["mappings"]; props = m.get("properties", {})
    real = (dates[i] is None or props.get(dates[i], {}).get("type") == "date") and (i == "study_with_chapters" or m.get("_source", {}).get("enabled") is False)
    n = es(f"/{i}/_count").get("count", -1)
    try: w = int(w)
    except ValueError: w = -1
    lag = abs(n - w) <= max(10, w // 100)   # the ingestor lags a little; these indexes refresh every 300 s by design
    line(real and lag and w >= 0, f"{i:20} {n} docs, MongoDB {w}" + ("" if real else " — WRONG MAPPING (auto-created?)") + ("" if lag else " — COUNT MISMATCH"))
for c in ("lila-docker-lila_search_app-1", "lila-docker-lila_search_ingestor-1"):
    st = subprocess.run(["docker", "inspect", "-f", "{{.State.Status}}", c], capture_output=True, text=True).stdout.strip()
    line(st == "running", f"{c} {st or 'missing'}")
sys.exit(bad)
PY
}

if [ "$MODE" = check ]; then check; r=$?; echo "SEARCH-CHECK: $([ $r = 0 ] && echo 'ALL OK' || echo "$r PROBLEM(S)")"; exit $r; fi

exec 9>/run/lock/chess-search-rebuild.lock; flock -n 9 || { echo "another rebuild is running"; exit 1; }
B=/root/search-backups/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$B"; chmod 700 /root/search-backups "$B"
log "REBUILD start; backup -> $B"
/usr/local/bin/chess-mongodump.sh || { log "FAIL mongodump"; exit 1; }
tail -1 /var/log/chess-mongodump.log | grep -q ' OK .*verified=yes' || { log "FAIL mongodump not verified"; exit 1; }
tail -1 /var/log/chess-mongodump.log >> "$B/mongodump.txt"
es 'localhost:9200/_cat/indices?v' > "$B/cat-indices.txt"; es 'localhost:9200/_cluster/settings' > "$B/cluster-settings.json"
es 'localhost:9200/_all/_settings' > "$B/index-settings.json"; es 'localhost:9200/_all/_mapping' > "$B/index-mappings.json"
es -XPOST 'localhost:9200/_flush' > /dev/null
tar -C "$(docker volume inspect -f '{{.Mountpoint}}' lila-docker_es_data)" -czf "$B/es_data-volume.tar.gz" . || { log "FAIL volume copy"; exit 1; }
log "backup OK: $(du -sh "$B" | cut -f1)"
ls -1d /root/search-backups/*/ | head -n -3 | while read -r d; do rm -rf -- "$d"; log "removed old backup $d"; done

es -XPUT 'localhost:9200/_cluster/settings' -H 'Content-Type: application/json' \
   -d "{\"persistent\":{\"action.auto_create_index\":\"$GUARD\"}}" > /dev/null
docker compose stop lila_search_ingestor >/dev/null 2>&1; log "ingestor paused"
for i in $INDEXES; do es -XDELETE "localhost:9200/$i" > /dev/null; done; log "dropped: $INDEXES"
cli() { timeout 1800 docker compose run --rm --no-deps lila_search_ingestor_cli index --all --since 0 --refresh >> "$LOG" 2>&1; }
cli; r1=$?
docker compose start lila_search_ingestor >/dev/null 2>&1; log "ingestor resumed"
[ $r1 = 0 ] || { log "FAIL full index (exit $r1) — rebuild again, or restore the volume copy (see header)"; exit 1; }
cli || { log "FAIL catch-up pass"; exit 1; }   # anything that changed while the ingestor was paused
log "full index + catch-up pass done"
check | tee -a "$LOG"; r=${PIPESTATUS[0]}
log "REBUILD $([ $r = 0 ] && echo 'OK' || echo "done with $r PROBLEM(S)")"; exit $r
