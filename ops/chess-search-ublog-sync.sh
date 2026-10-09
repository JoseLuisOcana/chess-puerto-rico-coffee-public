#!/bin/bash
# chess-search-ublog-sync.sh — keep the BLOG search index current (2026-10-08).
#
# lila-search >= 3.5 no longer runs a live blog ingestor (upstream commented it out, commit cc8e3f8, 2026-03), so blog posts
# reach search only when the CLI indexes them. Every 10 minutes (cron /etc/cron.d/chess-search-ublog-sync) this:
#   1. runs the upstream CLI for the ublog index from the beginning (a few posts here: seconds). It indexes every LIVE post
#      and removes posts that are no longer live or were rated spam. Blog search only SHOWS posts a moderator approved
#      (automod.quality >= weak; on this site set by the Weak/Good buttons — see CLAUDE.md "Approve a blog post");
#   2. deletes index entries whose post no longer exists in MongoDB (hard-deleted posts; the CLI cannot see those).
# So an approved post is searchable within ~10 minutes; the community list shows it at once (it reads MongoDB).
# Shares the lock of chess-search-rebuild.sh: never runs during a rebuild.
# Env (staging/tests): CHESS_PROJECT, CHESS_PREFIX. Log: /var/log/chess-search-ublog-sync.log (one line per run).
set -uo pipefail
PROJECT=${CHESS_PROJECT:-/opt/chess/lila-docker}; PREFIX=${CHESS_PREFIX:-lila-docker}; export PREFIX
if [ "$PREFIX" = lila-docker ]; then LOG=/var/log/chess-search-ublog-sync.log; else LOG=$PROJECT/../chess-search-ublog-sync.log; fi
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
exec 9>"/run/lock/chess-search-$PREFIX.lock"; flock -n 9 || { log "SKIP a rebuild or another sync is running"; exit 0; }
cd "$PROJECT" || exit 1
t0=$(date +%s); OUT=$(mktemp)
if ! timeout 600 docker compose run --rm --no-deps lila_search_ingestor_cli index --index ublog --since 0 --refresh > "$OUT" 2>&1; then
  log "FAIL cli: $(grep -m1 -E 'Exception|ERROR' "$OUT" | cut -c1-160)"; rm -f "$OUT"; exit 1
fi
rm -f "$OUT"
python3 -I - <<'PY' >> "$LOG" 2>&1
import json, os, subprocess, time
P = os.environ["PREFIX"]
def es(*a):
    r = subprocess.run(["docker", "exec", f"{P}-elasticsearch-1", "curl", "-s", *a], capture_output=True, text=True)
    return json.loads(r.stdout or "{}")
hits = es("-H", "Content-Type: application/json", "localhost:9200/ublog/_search?size=10000",
          "-d", '{"_source": false, "query": {"match_all": {}}}').get("hits", {}).get("hits", [])
ids = {h["_id"] for h in hits}
r = subprocess.run(["docker", "exec", f"{P}-mongodb-1", "mongosh", "--quiet", "lichess", "--eval",
                    'print(JSON.stringify(db.ublog_post.find({live:true, "automod.quality":{$ne:0}},{_id:1}).toArray().map(p=>p._id)))'],
                   capture_output=True, text=True)
live = set(json.loads(r.stdout.strip().splitlines()[-1]))
stale = sorted(ids - live)
for i in stale: es("-XDELETE", f"localhost:9200/ublog/_doc/{i}")
if stale: es("-XPOST", "localhost:9200/ublog/_refresh")
rated = es("localhost:9200/ublog/_count?q=quality:%5B1%20TO%20*%5D").get("count", "?")
print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} OK index {len(ids) - len(stale)} posts = MongoDB {len(live)} live, "
      f"{rated} approved (searchable); removed {len(stale)} deleted {stale[:5]}")
PY
rc=$?; [ $rc = 0 ] || { log "FAIL stale-entry cleanup (exit $rc)"; exit 1; }
exit 0
