#!/bin/bash
# chess-auto-feed.sh — keep the homepage "News" feed (daily_feed) current on chesspuertoricocoffee.com
#
# Added 2026-10-03. Cron: /etc/cron.d/chess-auto-feed (Mon + Thu 08:00 AST — the server TZ is
# America/Puerto_Rico, which has no DST). Log: /var/log/chess-auto-feed.log.
#
# Each run posts at most ONE item, built only from real data through a fixed template
# (no generated prose, nothing copied from Lichess posts):
#   1. lichess.org/api/broadcast — ONE request per run, identified User-Agent, no retries.
#      The top 1-2 official events with a round ongoing or starting before Sunday 23:59 AST,
#      in Lichess's own order (tier first). Multi-section events collapse to their `group`.
#      Names that look like they carry a person (" vs ", "Memorial", a surname from the
#      event's own info.players) are skipped: no personal names in the feed.
#   2. Our MongoDB, since the previous auto post (for the very first one: since the newest
#      published post): finished games (imports excluded), finished arenas + swiss with >= 2
#      players, new enabled accounts. Zero counts are left out, never shown as "0".
#   3. The next scheduled NON-hourly arena + /training/daily. lila deletes an empty
#      tournament when it ends (TournamentApi.scala `case 0 => destroy`), so an hourly link
#      404s within ~2 h; a daily/weekly/monthly one stays valid far longer.
#
# Safety:
#   - Lichess down / 429 / bad JSON -> our own data only. No events AND no non-zero counts
#     (or only events already in the previous auto post) -> skip. Never posts empty.
#   - One post per AST day (_id "auto-YYYYMMDD"); never content identical to any post.
#   - daily_feed is exported to /var/backups/chess-auto-feed/ before every write (last 30 kept).
#   - Keeps the newest 5 published posts public; older ones get public:false, never deleted.
#     Future-dated (scheduled) posts are not touched.
#   - lila caches the feed and reloads it LAZILY: refreshAfterWrite(1 min) fires only when
#     something reads the store, and the homepage reads a copy that only that reload updates.
#     A direct DB write stays invisible until then, so the script pokes /feed.atom (the only
#     anonymous reader), retries after 65 s, and checks the homepage by IP + SNI.
#     A failed check goes to stderr (cron mail) and exits 2; the DB write itself stands.
#
# Usage: chess-auto-feed.sh [--dry-run] [--lichess-file FILE]
#   --dry-run            build and print the post and the prune list; write nothing
#                        (still makes the one Lichess request unless --lichess-file is given)
#   --lichess-file FILE  read NDJSON from FILE instead of calling the API (tests; no request)
#   LICHESS_API_URL=...  override the endpoint (e.g. an unreachable URL to test the fallback)
#
# Undo: the log names the posted id and every id it hid. Hide a post with
#   db.daily_feed.updateOne({_id: "auto-YYYYMMDD"}, {$set: {public: false}})
# and re-show hidden ones with {$set: {public: true}}, then GET /feed.atom twice 65 s apart.

set -euo pipefail

LOG=/var/log/chess-auto-feed.log

if [[ $EUID -ne 0 ]]; then
  echo "chess-auto-feed: run as root (it needs docker)" >&2
  exit 1
fi

exec 9>/run/lock/chess-auto-feed.lock
if ! flock -n 9; then
  echo "$(date -u +%FT%TZ) SKIP another run holds /run/lock/chess-auto-feed.lock" >> "$LOG"
  exit 0
fi

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, json, os, re, subprocess, sys, time
import urllib.error, urllib.request
from zoneinfo import ZoneInfo

LOG = "/var/log/chess-auto-feed.log"
PROJECT = "/opt/chess/lila-docker"
SITE_HOST = "chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"  # connect by IP, SNI on the real name, like the other health checks
LICHESS_URL = os.environ.get("LICHESS_API_URL", "https://lichess.org/api/broadcast?nb=30")
USER_AGENT = ("chesspuertoricocoffee.com-auto-feed/1.0 "
              "(+https://chesspuertoricocoffee.com; system@chesspuertoricocoffee.com)")
BACKUP_DIR = "/var/backups/chess-auto-feed"
KEEP_BACKUPS = 30
KEEP_PUBLIC = 5
MAX_EVENTS = 2
SPONSOR = "☕♞ Sponsored by PuertoRicoCoffeeShop.com"
AST = ZoneInfo("America/Puerto_Rico")
UTC = dt.timezone.utc

ap = argparse.ArgumentParser(prog="chess-auto-feed.sh")
ap.add_argument("--dry-run", action="store_true", help="build and print, write nothing")
ap.add_argument("--lichess-file", help="read broadcast NDJSON from FILE instead of the API")
args = ap.parse_args()
DRY = args.dry_run
TAG = "DRY" if DRY else "RUN"


def log(msg, err=False):
    line = f"{dt.datetime.now(UTC):%Y-%m-%dT%H:%M:%SZ} {TAG} {msg}"
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")
    if err:
        print(line, file=sys.stderr)
    elif DRY or sys.stdout.isatty():
        print(line)


def die(msg, code=1):
    log("ERROR " + msg, err=True)
    sys.exit(code)


def docker_mongo(*cmd, timeout=120):
    return subprocess.run(["/usr/bin/docker", "compose", "exec", "-T", "mongodb", *cmd],
                          cwd=PROJECT, capture_output=True, text=True, timeout=timeout)


def mongo(js):
    """Run JS in mongosh; the JS must print one line '@@JSON@@' + JSON.stringify(result)."""
    r = docker_mongo("mongosh", "lichess", "--quiet", "--eval", js)
    out = [l for l in r.stdout.splitlines() if l.startswith("@@JSON@@")]
    if r.returncode != 0 or not out:
        die(f"mongosh rc={r.returncode}: {(r.stderr or r.stdout).strip()[-400:]}")
    return json.loads(out[-1][len("@@JSON@@"):])


def md(text, limit=100):
    """One line of plain text, safe inside Markdown (data never becomes markup)."""
    s = " ".join(str(text).split())
    if len(s) > limit:
        s = s[:limit - 1].rstrip() + "…"
    return re.sub(r"([\\`*_\[\]<>|~#])", r"\\\1", s)


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def when(iso):
    t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(AST)
    return f"{t:%a %b} {t.day}, {t.hour % 12 or 12}:{t:%M} {'AM' if t.hour < 12 else 'PM'} AST"


now = dt.datetime.now(UTC).replace(microsecond=0)
now_ast = now.astimezone(AST)
end_of_week = (now_ast + dt.timedelta(days=6 - now_ast.weekday())).replace(
    hour=23, minute=59, second=59)  # Sunday 23:59:59 AST
post_id = f"auto-{now_ast:%Y%m%d}"

# ---------------------------------------------------------------- 1. Lichess broadcasts
def fetch_broadcasts():
    if args.lichess_file:
        with open(args.lichess_file, encoding="utf-8") as f:
            raw = f.read()
    else:
        req = urllib.request.Request(LICHESS_URL, headers={
            "User-Agent": USER_AGENT, "Accept": "application/x-ndjson"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                raw = r.read(5_000_000).decode("utf-8")
        except urllib.error.HTTPError as e:
            return None, f"HTTP {e.code}" + (" (rate-limited, not retrying)" if e.code == 429 else "")
        except Exception as e:  # DNS, timeout, TLS, refused ...
            return None, f"{type(e).__name__}: {e}"
    try:
        items = [json.loads(l) for l in raw.splitlines() if l.strip()]
    except ValueError as e:
        return None, f"bad NDJSON: {e}"
    if not all(isinstance(i, dict) and isinstance(i.get("tour"), dict) for i in items):
        return None, "unexpected JSON shape"
    return items, f"{len(items)} broadcasts"


NAME_PATTERNS = [
    re.compile(r"\s(?:vs?\.?)\s", re.I),                # "A vs B", "A v. B"
    re.compile(r"memorial", re.I),                       # named after a person
    re.compile(r"\b[A-Z][a-z]+[–—][A-Z][a-z]+\b"),      # "Carlsen–Nakamura"
]


def has_personal_name(name, tour):
    if any(p.search(name) for p in NAME_PATTERNS):
        return True
    players = str((tour.get("info") or {}).get("players") or "")
    surnames = {w.casefold() for w in re.findall(r"[^\W\d_]{3,}", players)}
    return any(w.casefold() in surnames for w in re.findall(r"[^\W\d_]{3,}", name))


def this_week(rounds):
    lo, hi = now.timestamp() * 1000, end_of_week.timestamp() * 1000
    for r in rounds or []:
        s = r.get("startsAt")
        if r.get("ongoing") or (isinstance(s, (int, float)) and lo <= s <= hi and not r.get("finished")):
            return True
    return False


# ---------------------------------------------------------------- 2+3. Our database
P = {"now": now.isoformat(), "postId": post_id}
st = mongo("const P = " + json.dumps(P) + r""";
const now = new Date(P.now);
const lastAuto = db.daily_feed.find({_id: {$regex: "^auto-"}}).sort({at: -1}).limit(1).toArray()[0] || null;
const newest = db.daily_feed.find({public: true, at: {$lte: now}}).sort({at: -1}).limit(1).toArray()[0] || null;
const since = lastAuto ? lastAuto.at : (newest ? newest.at : new Date(now - 7 * 864e5));
const win = {$gte: since, $lt: now};
const games = db.game5.countDocuments({ca: win, s: {$gte: 30, $ne: 37}, so: {$nin: [7, 9]}});
const arenas = db.tournament2.countDocuments({status: 30, startsAt: win, nbPlayers: {$gte: 2}});
const swiss = db.swiss.countDocuments({finishedAt: win, nbPlayers: {$gte: 2}});
const players = db.user4.countDocuments({createdAt: win, enabled: true, _id: {$ne: "lichess"},
  title: {$ne: "BOT"}, marks: {$nin: ["alt", "troll", "engine", "boost"]}});
const proj = {name: 1, startsAt: 1, "schedule.freq": 1};
const upcoming = {status: 10, startsAt: {$gt: now}};
const next =
  db.tournament2.find({...upcoming, "schedule.freq": {$exists: true, $ne: "hourly"}}, proj).sort({startsAt: 1}).limit(1).toArray()[0] ||
  db.tournament2.find({...upcoming, schedule: {$exists: true}}, proj).sort({startsAt: 1}).limit(1).toArray()[0] || null;
print("@@JSON@@" + JSON.stringify({
  since, sinceFrom: lastAuto ? "previous auto post " + lastAuto._id : (newest ? "newest post " + newest._id : "7-day default"),
  lastAuto: lastAuto && {id: lastAuto._id, content: lastAuto.content},
  games, arenas, swiss, players,
  next: next && {id: next._id, name: next.name, startsAt: next.startsAt, freq: next.schedule.freq},
  todayExists: !!db.daily_feed.findOne({_id: P.postId}),
  contents: db.daily_feed.find({}, {content: 1}).toArray().map(d => d.content),
  published: db.daily_feed.find({public: true, at: {$lte: now}}, {_id: 1}).sort({at: -1}).toArray().map(d => d._id)
}));""")

# Lichess (section 1) runs after the DB read, so a same-day re-run never spends its request.
broadcasts, lichess_note = ((None, "not called: already posted today") if st["todayExists"]
                             else fetch_broadcasts())
lichess_ok = broadcasts is not None
events, seen, rejected = [], set(), []
if lichess_ok:
    for b in broadcasts:
        tour = b["tour"]
        if not this_week(b.get("rounds")):
            continue
        name = str(b.get("group") or tour.get("name") or "").strip()
        url = str(tour.get("url") or "")
        if not name or not re.fullmatch(r"https://lichess\.org/broadcast/[A-Za-z0-9/_-]+", url):
            continue
        if has_personal_name(name, tour):
            rejected.append(name)
            continue
        if name.casefold() in seen:
            continue
        seen.add(name.casefold())
        events.append({"name": name, "url": url})
    events = events[:MAX_EVENTS]
    log(f"lichess OK {lichess_note}; this week (to {end_of_week:%a %b %d %H:%M} AST): "
        f"picked {[e['name'] for e in events]}"
        + (f"; skipped as personal names {sorted(set(rejected))}" if rejected else ""))
else:
    log(f"lichess {lichess_note}" if st["todayExists"]
        else f"WARN lichess FAILED ({lichess_note}) — posting our own data only")

since_ast = dt.datetime.fromisoformat(st["since"].replace("Z", "+00:00")).astimezone(AST)
tours_held = st["arenas"] + st["swiss"]
log(f"window since {st['since']} ({st['sinceFrom']}): games={st['games']} "
    f"tournaments={tours_held} (arena {st['arenas']}, swiss {st['swiss']}) new_players={st['players']}; "
    f"next={st['next'] and (st['next']['id'], st['next']['name'], st['next']['freq'], st['next']['startsAt'])}")

# ---------------------------------------------------------------- build the post
stats = []
if st["games"] > 0:
    stats.append(plural(st["games"], "game played", "games played"))
if tours_held > 0:
    stats.append(plural(tours_held, "tournament held", "tournaments held"))
if st["players"] > 0:
    stats.append(plural(st["players"], "new player", "new players"))

parts = []
if events:
    parts.append("🏆 **This week in chess:** " + " · ".join(
        f"{md(e['name'])} — [Follow live on Lichess]({e['url']})" for e in events))
if stats:
    parts.append(f"📊 **On Chess Puerto Rico Coffee since {since_ast:%a %b} {since_ast.day}:** "
                 + " · ".join(stats))
tail = []
nxt = st["next"]
if nxt and re.fullmatch(r"[A-Za-z0-9]{8}", str(nxt["id"])):
    tail.append(f"📅 **Next tournament:** [{md(nxt['name'], 60)}](/tournament/{nxt['id']}) — {when(nxt['startsAt'])}")
tail.append("🧩 [Puzzle of the Day](/training/daily)")
parts.append(" · ".join(tail))
parts.append(SPONSOR)
content = "\n\n".join(parts)
flair = "activity.trophy" if events else "objects.chart-increasing"

# previous auto post: which events did it already announce?
prev = set()
for m in re.finditer(r"(?:\*\*This week in chess:\*\* |· )(.+?) — \[Follow live on Lichess\]\(([^)\s]+)\)",
                     (st["lastAuto"] or {}).get("content") or ""):
    prev.update(m.groups())
new_events = [e for e in events if md(e["name"]) not in prev and e["url"] not in prev]

skip = None
if st["todayExists"]:
    skip = f"already posted today ({post_id} exists)"
elif not stats and not new_events:
    skip = ("nothing new to say: no non-zero counts and "
            + ("no Lichess data" if not lichess_ok else
               "no events this week" if not events else "the same events as the previous auto post"))
elif content in st["contents"]:
    skip = "identical content is already in the feed"

published = ([] if skip else [post_id]) + st["published"]
visible, hide = published[:KEEP_PUBLIC], published[KEEP_PUBLIC:]

if skip:
    log(f"SKIP {skip}")
else:
    log(f"POST {post_id} flair={flair} content={json.dumps(content, ensure_ascii=False)}")
log(f"prune: keep public {visible}; set public:false on {hide or 'nothing'}")

if DRY:
    if not skip:
        print(f"\n----- would post {post_id} (flair {flair}) -----\n{content}\n" + "-" * 40)
    sys.exit(0)

if skip and not hide:
    sys.exit(0)

# ---------------------------------------------------------------- write (backup first)
os.makedirs(BACKUP_DIR, mode=0o750, exist_ok=True)
r = docker_mongo("mongoexport", "--quiet", "--db", "lichess", "--collection", "daily_feed", "--jsonArray")
try:
    n_backup = len(json.loads(r.stdout)) if r.returncode == 0 else -1
except ValueError:
    n_backup = -1
if n_backup < 1:
    die(f"backup of daily_feed failed (rc={r.returncode}): {r.stderr.strip()[-300:]} — nothing written")
bpath = f"{BACKUP_DIR}/daily_feed-auto-{now:%Y%m%dT%H%M%SZ}.json"
with open(bpath, "w", encoding="utf-8") as f:
    f.write(r.stdout)
os.chmod(bpath, 0o640)
for old in sorted(glob.glob(f"{BACKUP_DIR}/daily_feed-auto-*.json"))[:-KEEP_BACKUPS]:
    os.remove(old)
log(f"backup {bpath} ({n_backup} docs)")

W = {"keep": KEEP_PUBLIC, "doc": None if skip else {
    "_id": post_id, "content": content, "public": True, "at": now.isoformat(), "flair": flair}}
res = mongo("const P = " + json.dumps(W) + r""";
const res = {};
if (P.doc) res.inserted = db.daily_feed.insertOne({...P.doc, at: new Date(P.doc.at)}).insertedId;
const pub = db.daily_feed.find({public: true, at: {$lte: new Date()}}, {_id: 1}).sort({at: -1}).toArray().map(d => d._id);
res.visible = pub.slice(0, P.keep);
res.hidden = pub.slice(P.keep);
res.modified = res.hidden.length ? db.daily_feed.updateMany({_id: {$in: res.hidden}, public: true}, {$set: {public: false}}).modifiedCount : 0;
print("@@JSON@@" + JSON.stringify(res));""")
log(f"WROTE inserted={res.get('inserted')} hid={res['hidden']} (modified {res['modified']}) visible={res['visible']}")

# ---------------------------------------------------------------- make lila reload, verify
def fetch(path):
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "-A", USER_AGENT,
                        "--resolve", f"{SITE_HOST}:443:{PROBE_IP}", f"https://{SITE_HOST}{path}"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout


shown = []
for attempt in range(3):
    fetch("/feed.atom")   # an access older than 1 min triggers the store reload
    time.sleep(3)
    shown = re.findall(r'href="/feed#([A-Za-z0-9_-]+)"', fetch("/"))
    if shown == res["visible"]:
        log(f"OK homepage feed shows {shown}")
        sys.exit(0)
    if attempt < 2:
        time.sleep(65)  # the store was reloaded < 1 min ago; wait out refreshAfterWrite
die(f"homepage feed shows {shown}, expected {res['visible']} — DB is updated; "
    "GET /feed.atom again or check lila", code=2)
PY
