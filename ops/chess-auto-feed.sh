#!/bin/bash
# chess-auto-feed.sh — keep the homepage "News" feed (daily_feed) current on chesspuertoricocoffee.com
#
# Added 2026-10-03. Cron: /etc/cron.d/chess-auto-feed (Mon + Thu 08:00 AST — the server TZ is
# America/Puerto_Rico, which has no DST). Log: /var/log/chess-auto-feed.log.
#
# SINCE 2026-11-24 (BUTTON 234, owner): NOTHING IS PUBLISHED AUTOMATICALLY. A scheduled run writes at most ONE
# DRAFT, to /var/lib/chess-auto-feed/draft.json (root only). It reaches the site only when the owner approves it:
#     sudo chess-approve                            shows what is waiting (news draft + videos)
#     sudo chess-approve news auto-YYYYMMDD         publishes that draft
#     sudo chess-approve reject-news auto-YYYYMMDD  drops it (a copy is kept)
# The draft is NOT stored in lila's daily_feed collection, on purpose: lila's anonymous /api/feed lists the 7 newest
# daily_feed documents WITHOUT looking at `public` (modules/feed Feed.scala, recentJson), so a public:false draft there
# would be readable by anyone. At most one draft waits: a newer run REPLACES a waiting one (its counts cover the same
# days and more; the old draft is kept in /var/backups/chess-auto-feed/). The Monday health report lists the waiting draft.
#
# Each draft is built only from real data through a fixed template (no generated prose, nothing copied from Lichess posts):
#   1. lichess.org/api/broadcast — ONE request per run, identified User-Agent, no retries.
#      The top 1-2 official events with a round ongoing or starting before Sunday 23:59 AST,
#      in Lichess's own order (tier first). Multi-section events collapse to their `group`.
#      Names that look like they carry a person (" vs ", "Memorial", a surname from the
#      event's own info.players) are skipped: no personal names in the feed.
#   2. Our MongoDB, since the previous PUBLISHED auto post (for the very first one: since the newest
#      published post): finished games (imports excluded), finished arenas + swiss with >= 2
#      players, new enabled accounts. Zero counts are left out, never shown as "0".
#      Games listed in /etc/chess-auto-feed-exclude-games (test games played on the live site, one
#      8-character id per line, '#' comments; missing file = none) are not counted (2026-10-08).
#   3. The next scheduled NON-hourly arena (name + time; an hourly one is over before most
#      readers see the post) + /training/daily. The name links to /tournament, the list page,
#      never to the tournament itself: lila deletes an empty tournament when it ends
#      (TournamentApi.scala `case 0 => destroy`), so a per-tournament link eventually 404s.
#
# Safety:
#   - Lichess down / 429 / bad JSON -> our own data only. No events AND no non-zero counts
#     (or only events already in the previous auto post) -> skip. Never an empty draft.
#   - One item per AST day (_id "auto-YYYYMMDD", draft or post); never content identical to any post or the waiting draft.
#   - Only --approve writes a post, and only the waiting draft the owner names, as public:true.
#   - daily_feed is exported to /var/backups/chess-auto-feed/ before every write to it (last 30 kept).
#     Every draft that leaves draft.json (replaced, approved, rejected) is kept there too (never deleted).
#   - Keeps the newest 5 published posts public; older ones get public:false, never deleted.
#     Future-dated (scheduled) posts are not touched.
#   - lila caches the feed and reloads it LAZILY: refreshAfterWrite(1 min) fires only when
#     something reads the store, and the homepage reads a copy that only that reload updates.
#     A direct DB write stays invisible until then, so after a write to daily_feed the script pokes
#     /feed.atom (the only anonymous reader of published posts), retries after 65 s, and checks the
#     homepage by IP + SNI. A failed check goes to stderr (cron mail) and exits 2; the DB write itself stands.
#
# Usage: chess-auto-feed.sh [--dry-run] [--lichess-file FILE]   the scheduled run: builds the draft
#        chess-auto-feed.sh --list-waiting                      prints the waiting draft (read-only)
#        chess-auto-feed.sh --approve -- auto-YYYYMMDD          publishes the waiting draft (the owner's approval)
#        chess-auto-feed.sh --reject -- auto-YYYYMMDD           drops the waiting draft (kept in the backups)
#   --dry-run            build and print the draft and the prune list; write nothing
#                        (still makes the one Lichess request unless --lichess-file is given)
#   --lichess-file FILE  read NDJSON from FILE instead of calling the API (tests; no request)
#   LICHESS_API_URL=...  override the endpoint (e.g. an unreachable URL to test the fallback)
#   Test hooks (BUTTON 234 tests only): CHESS_FEED_TEST_DB=test234<x> with CHESS_FEED_TEST_STATE=<absolute folder> use
#   that scratch database and folder (draft, backups, log) instead of lichess and the live paths; the scheduled mode then
#   needs --lichess-file (no Lichess request) and nothing checks the homepage.
#
# Undo a published post: db.daily_feed.updateOne({_id: "auto-YYYYMMDD"}, {$set: {public: false}}) and re-show hidden
# ones with {$set: {public: true}}, then GET /feed.atom twice 65 s apart. Undo BUTTON 234: PANIC-BUTTONS BUTTON 234.

set -euo pipefail

LOG=/var/log/chess-auto-feed.log

if [[ $EUID -ne 0 ]]; then
  echo "chess-auto-feed: run as root (it needs docker)" >&2
  exit 1
fi

exec 9>/run/lock/chess-auto-feed.lock
if ! flock -n 9; then
  case " $* " in
    *" --approve "*|*" --reject "*|*" --list-waiting "*)
      echo "chess-auto-feed: busy - a run holds /run/lock/chess-auto-feed.lock; nothing changed, try again in a few minutes" >&2
      exit 1;;
  esac
  echo "$(date -u +%FT%TZ) SKIP another run holds /run/lock/chess-auto-feed.lock" >> "$LOG"
  exit 0
fi

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, json, os, re, subprocess, sys, time
import urllib.error, urllib.request
from zoneinfo import ZoneInfo

PROJECT = "/opt/chess/lila-docker"
SITE_HOST = "chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"  # connect by IP, SNI on the real name, like the other health checks
LICHESS_URL = os.environ.get("LICHESS_API_URL", "https://lichess.org/api/broadcast?nb=30")
USER_AGENT = ("chesspuertoricocoffee.com-auto-feed/1.0 "
              "(+https://chesspuertoricocoffee.com; system@chesspuertoricocoffee.com)")
KEEP_BACKUPS = 30
KEEP_PUBLIC = 5
EXCLUDE_FILE = "/etc/chess-auto-feed-exclude-games"  # game ids never counted (live-site test games)
MAX_EVENTS = 2
SPONSOR = "☕♞ Sponsored by PuertoRicoCoffeeShop.com"
AST = ZoneInfo("America/Puerto_Rico")
UTC = dt.timezone.utc
ID_RE = r"auto-\d{8}"

# test hooks (BUTTON 234): a scratch database + folder, never the live ones
TEST_DB, TEST_STATE = os.environ.get("CHESS_FEED_TEST_DB", ""), os.environ.get("CHESS_FEED_TEST_STATE", "")
if bool(TEST_DB) != bool(TEST_STATE):
    sys.exit("chess-auto-feed: CHESS_FEED_TEST_DB and CHESS_FEED_TEST_STATE go together - nothing done")
TEST = bool(TEST_DB)
if TEST and (not re.fullmatch(r"test234[a-z0-9_]{0,20}", TEST_DB) or not os.path.isabs(TEST_STATE)
             or not os.path.isdir(TEST_STATE)
             or os.path.realpath(TEST_STATE).startswith(("/var/lib/", "/var/backups/", "/var/log/", "/var/www/"))):
    sys.exit("chess-auto-feed: refused test settings (database must be test234..., folder an existing absolute "
             "scratch folder) - nothing done")
DB = TEST_DB or "lichess"
STATE_DIR = TEST_STATE or "/var/lib/chess-auto-feed"
DRAFT = f"{STATE_DIR}/draft.json"
LOG = f"{TEST_STATE}/chess-auto-feed.log" if TEST else "/var/log/chess-auto-feed.log"
BACKUP_DIR = f"{TEST_STATE}/backups" if TEST else "/var/backups/chess-auto-feed"

ap = argparse.ArgumentParser(prog="chess-auto-feed.sh")
ap.add_argument("--dry-run", action="store_true", help="build and print, write nothing")
ap.add_argument("--lichess-file", help="read broadcast NDJSON from FILE instead of the API")
mode = ap.add_mutually_exclusive_group()
mode.add_argument("--list-waiting", action="store_true", help="print the draft that waits for approval")
mode.add_argument("--approve", action="store_true", help="publish the waiting draft named after --")
mode.add_argument("--reject", action="store_true", help="drop the waiting draft named after --")
ap.add_argument("ids", nargs="*", help="the draft id (auto-YYYYMMDD), only with --approve / --reject")
args = ap.parse_args()
MODE = "approve" if args.approve else "reject" if args.reject else "list" if args.list_waiting else "run"
if MODE in ("approve", "reject"):
    if len(args.ids) != 1 or not re.fullmatch(ID_RE, args.ids[0]):
        ap.error(f"--{MODE} needs exactly one draft id like auto-20261126")
if MODE != "run" and (args.dry_run or args.lichess_file):
    ap.error("--dry-run / --lichess-file go only with the scheduled run")
if MODE not in ("approve", "reject") and args.ids:
    ap.error("a draft id goes only with --approve or --reject")
if TEST and MODE == "run" and not args.lichess_file:
    ap.error("test mode needs --lichess-file (no Lichess request in tests)")
DRY = args.dry_run
TAG = "DRY" if DRY else {"run": "RUN", "approve": "APPROVE", "reject": "REJECT", "list": "LIST"}[MODE]


def log(msg, err=False):
    line = f"{dt.datetime.now(UTC):%Y-%m-%dT%H:%M:%SZ} {TAG} {msg}"
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")
    if err:
        print(line, file=sys.stderr)
    elif DRY or MODE != "run" or sys.stdout.isatty():
        print(line)


def die(msg, code=1):
    log("ERROR " + msg, err=True)
    sys.exit(code)


def read_excluded_games():
    """Game ids the counts must skip. A missing file means none; a bad line is reported and ignored."""
    try:
        lines = open(EXCLUDE_FILE, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return []
    except OSError as e:
        log(f"WARN cannot read {EXCLUDE_FILE} ({e}); counting every game", err=True)
        return []
    ids = []
    for n, line in enumerate(lines, 1):
        tok = line.split("#", 1)[0].strip()
        if not tok:
            continue
        if re.fullmatch(r"[A-Za-z0-9]{8}", tok):
            ids.append(tok)
        else:
            log(f"WARN {EXCLUDE_FILE} line {n} is not an 8-character game id, ignored: {tok[:40]!r}", err=True)
    return ids


def docker_mongo(*cmd, timeout=120):
    return subprocess.run(["/usr/bin/docker", "compose", "exec", "-T", "mongodb", *cmd],
                          cwd=PROJECT, capture_output=True, text=True, timeout=timeout)


def mongo(js):
    """Run JS in mongosh; the JS must print one line '@@JSON@@' + JSON.stringify(result)."""
    r = docker_mongo("mongosh", DB, "--quiet", "--eval", js)
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


# ---------------------------------------------------------------- the waiting draft (BUTTON 234)
def read_draft():
    """The waiting draft, or None. A file this script did not write stops everything: never guess."""
    try:
        with open(DRAFT, encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        die(f"cannot read {DRAFT} ({type(e).__name__}) - look at it, then fix or move it by hand; nothing changed")
    if not (isinstance(d, dict) and set(d) == {"_id", "content", "at", "flair"}
            and isinstance(d["_id"], str) and re.fullmatch(ID_RE, d["_id"])
            and isinstance(d["content"], str) and d["content"].strip()
            and isinstance(d["flair"], str) and isinstance(d["at"], str)):
        die(f"{DRAFT} is not a draft this script wrote - look at it, then fix or move it by hand; nothing changed")
    return d


def write_json_file(path, data):
    tmp = path + ".tmp"   # in a root-only folder
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def kept_path(why, d):
    os.makedirs(BACKUP_DIR, mode=0o750, exist_ok=True)
    p = f"{BACKUP_DIR}/draft-{why}-{d['_id']}-{now:%Y%m%dT%H%M%SZ}.json"
    if os.path.exists(p):
        die(f"{p} exists already - nothing changed")
    return p


def move_draft_away(why, d):
    """approved / rejected: draft.json is MOVED (renamed) into BACKUP_DIR - nothing is deleted."""
    p = kept_path(why, d)
    os.replace(DRAFT, p)
    return p


# ---------------------------------------------------------------- writes to daily_feed (backup first) + check
def backup_feed():
    os.makedirs(BACKUP_DIR, mode=0o750, exist_ok=True)
    r = docker_mongo("mongoexport", "--quiet", "--db", DB, "--collection", "daily_feed", "--jsonArray")
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


def write_feed(doc):
    """Insert doc (only --approve passes one), then keep the newest KEEP_PUBLIC published posts public."""
    W = {"keep": KEEP_PUBLIC, "doc": doc}
    res = mongo("const P = " + json.dumps(W) + r""";
const res = {};
if (P.doc) res.inserted = db.daily_feed.insertOne({...P.doc, at: new Date(P.doc.at)}).insertedId;
const pub = db.daily_feed.find({public: true, at: {$lte: new Date()}}, {_id: 1}).sort({at: -1}).toArray().map(d => d._id);
res.visible = pub.slice(0, P.keep);
res.hidden = pub.slice(P.keep);
res.modified = res.hidden.length ? db.daily_feed.updateMany({_id: {$in: res.hidden}, public: true}, {$set: {public: false}}).modifiedCount : 0;
print("@@JSON@@" + JSON.stringify(res));""")
    log(f"WROTE inserted={res.get('inserted')} hid={res['hidden']} (modified {res['modified']}) visible={res['visible']}")
    return res


def fetch(path):
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "-A", USER_AGENT,
                        "--resolve", f"{SITE_HOST}:443:{PROBE_IP}", f"https://{SITE_HOST}{path}"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout


def verify_homepage(visible):
    """Make lila reload the feed store, then check the homepage shows exactly `visible`. Exits."""
    if TEST:
        log(f"OK (test mode: no homepage check) visible would be {visible}")
        sys.exit(0)
    shown = []
    for attempt in range(3):
        fetch("/feed.atom")   # an access older than 1 min triggers the store reload
        time.sleep(3)
        shown = re.findall(r'href="/feed#([A-Za-z0-9_-]+)"', fetch("/"))
        if shown == visible:
            log(f"OK homepage feed shows {shown}")
            sys.exit(0)
        if attempt < 2:
            time.sleep(65)  # the store was reloaded < 1 min ago; wait out refreshAfterWrite
    die(f"homepage feed shows {shown}, expected {visible} — DB is updated; "
        "GET /feed.atom again or check lila", code=2)


# ---------------------------------------------------------------- owner's modes: list / reject / approve
if MODE == "list":
    d = read_draft()
    if not d:
        print("NEWS: no draft is waiting for approval.")
        sys.exit(0)
    print(f"NEWS draft waiting for approval: {d['_id']} (written {when(d['at'])})\n")
    for line in d["content"].split("\n"):
        print("    " + line)
    print(f"\n  Publish it:  sudo chess-approve news {d['_id']}"
          f"\n  Drop it:     sudo chess-approve reject-news {d['_id']}")
    sys.exit(0)

if MODE in ("approve", "reject"):
    d = read_draft()
    want = args.ids[0]
    if not d or d["_id"] != want:
        die(f"no waiting draft {want} (waiting now: {d['_id'] if d else 'none'}) - nothing changed")
    if MODE == "reject":
        p = move_draft_away("rejected", d)
        log(f"REJECTED draft {want} - not published; kept as {p}")
        sys.exit(0)
    ex = mongo("const P = " + json.dumps({"id": want, "content": d["content"]}) + r""";
print("@@JSON@@" + JSON.stringify({exists: !!db.daily_feed.findOne({_id: P.id}),
  identical: !!db.daily_feed.findOne({content: P.content})}));""")
    if ex["exists"]:
        die(f"{want} is already in daily_feed - nothing changed (the draft stays; drop it with reject-news)")
    if ex["identical"]:
        die("a post with exactly this text is already in the feed - nothing changed (drop the draft with reject-news)")
    backup_feed()
    res = write_feed({"_id": want, "content": d["content"], "public": True, "at": d["at"], "flair": d["flair"]})
    p = move_draft_away("approved", d)
    log(f"APPROVED {want} - published by the owner; the draft is kept as {p}")
    if want not in res["visible"]:
        log(f"WARN {want} is older than the newest {KEEP_PUBLIC} published posts, so it was hidden again at once", err=True)
    verify_homepage(res["visible"])

# ---------------------------------------------------------------- the scheduled run: 1. Lichess broadcasts
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
P = {"now": now.isoformat(), "postId": post_id, "excludeGames": read_excluded_games()}
st = mongo("const P = " + json.dumps(P) + r""";
const now = new Date(P.now);
const lastAuto = db.daily_feed.find({_id: {$regex: "^auto-"}}).sort({at: -1}).limit(1).toArray()[0] || null;
const newest = db.daily_feed.find({public: true, at: {$lte: now}}).sort({at: -1}).limit(1).toArray()[0] || null;
const since = lastAuto ? lastAuto.at : (newest ? newest.at : new Date(now - 7 * 864e5));
const win = {$gte: since, $lt: now};
const gameQ = {ca: win, s: {$gte: 30, $ne: 37}, so: {$nin: [7, 9]}};
const games = db.game5.countDocuments({...gameQ, _id: {$nin: P.excludeGames}});
const gamesExcluded = P.excludeGames.length ? db.game5.countDocuments({...gameQ, _id: {$in: P.excludeGames}}) : 0;
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
  games, gamesExcluded, arenas, swiss, players,
  next: next && {id: next._id, name: next.name, startsAt: next.startsAt, freq: next.schedule.freq},
  todayExists: !!db.daily_feed.findOne({_id: P.postId}),
  contents: db.daily_feed.find({}, {content: 1}).toArray().map(d => d.content),
  published: db.daily_feed.find({public: true, at: {$lte: now}}, {_id: 1}).sort({at: -1}).toArray().map(d => d._id)
}));""")
draft = read_draft()
today_exists = st["todayExists"] or bool(draft and draft["_id"] == post_id)

# Lichess (section 1) runs after the DB read, so a same-day re-run never spends its request.
broadcasts, lichess_note = ((None, "not called: already a post or draft today") if today_exists
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
    log(f"lichess {lichess_note}" if today_exists
        else f"WARN lichess FAILED ({lichess_note}) — drafting from our own data only")

since_ast = dt.datetime.fromisoformat(st["since"].replace("Z", "+00:00")).astimezone(AST)
tours_held = st["arenas"] + st["swiss"]
log(f"window since {st['since']} ({st['sinceFrom']}): games={st['games']}"
    + (f" (+{st['gamesExcluded']} not counted: {EXCLUDE_FILE})" if st["gamesExcluded"] else "") + " "
    f"tournaments={tours_held} (arena {st['arenas']}, swiss {st['swiss']}) new_players={st['players']}; "
    f"next={st['next'] and (st['next']['id'], st['next']['name'], st['next']['freq'], st['next']['startsAt'])}")

# ---------------------------------------------------------------- build the draft
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
if nxt:
    tail.append(f"📅 **Next tournament:** [{md(nxt['name'], 60)}](/tournament) — {when(nxt['startsAt'])}")
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
if today_exists:
    skip = f"already a post or a draft today ({post_id})"
elif not stats and not new_events:
    skip = ("nothing new to say: no non-zero counts and "
            + ("no Lichess data" if not lichess_ok else
               "no events this week" if not events else "the same events as the previous auto post"))
elif content in st["contents"] or (draft and content == draft["content"]):
    skip = "identical content is already in the feed or in the waiting draft"

visible, hide = st["published"][:KEEP_PUBLIC], st["published"][KEEP_PUBLIC:]

if skip:
    log(f"SKIP {skip}" + (f" (draft {draft['_id']} still waits for approval)" if draft else ""))
else:
    log(f"DRAFT {post_id} flair={flair} content={json.dumps(content, ensure_ascii=False)}")
log(f"prune: keep public {visible}; set public:false on {hide or 'nothing'}")

if DRY:
    if not skip:
        print(f"\n----- would save draft {post_id} (flair {flair}) - NOT published, it waits for approval -----\n"
              f"{content}\n" + "-" * 40
              + (f"\n(it would replace the waiting draft {draft['_id']})" if draft else ""))
    sys.exit(0)

if skip and not hide:
    sys.exit(0)

# ---------------------------------------------------------------- write: the draft, then the prune (if any)
if not skip:
    os.makedirs(STATE_DIR, mode=0o750, exist_ok=True)
    if draft:
        p = kept_path("replaced", draft)
        write_json_file(p, draft)
        log(f"replaced the waiting draft {draft['_id']} (never approved; kept as {p})")
    write_json_file(DRAFT, {"_id": post_id, "content": content, "at": now.isoformat(), "flair": flair})
    log(f"DRAFT SAVED {post_id} - NOT published; it waits for the owner: sudo chess-approve news {post_id}")
if hide:
    backup_feed()
    res = write_feed(None)
    verify_homepage(res["visible"])
log(f"OK draft {post_id} waits for approval; nothing published")
PY
