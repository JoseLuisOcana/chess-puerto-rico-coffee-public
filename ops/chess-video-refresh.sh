#!/bin/bash
# chess-video-refresh.sh — weekly refresh of the homepage "🎥 Chess Videos" strip on chesspuertoricocoffee.com
#
# Added 2026-10-03. Cron: /etc/cron.d/chess-video-refresh (Sun 07:00 AST — the server TZ is
# America/Puerto_Rico, no DST). Log: /var/log/chess-video-refresh.log.
#
# SINCE 2026-11-24 (BUTTON 234, owner): NOTHING IS PUBLISHED AUTOMATICALLY. New videos that pass every check below go
# on a WAITING LIST, /var/lib/chess-video-refresh/pending.json (root only) - NOT into lila's library, so they are not
# on /video and cannot reach the homepage strip. Only the owner's approval adds them to the library:
#     sudo chess-approve                                  shows what is waiting (news draft + videos)
#     sudo chess-approve video <id> [<id> ...]            checks each one again with YouTube, then adds it to /video
#     sudo chess-approve reject-video <id> [<id> ...]     drops it; it is never proposed again
# A waiting video not decided in 28 days drops off the list by itself (it is never published). The homepage strip is
# chosen only from the library (= approved videos); an approved video reaches the strip at the next refresh run.
# The weekly job itself is PAUSED since 2026-11-24 (schedule line commented out in /etc/cron.d/chess-video-refresh,
# Codex chess review finding 01: this root job writes into the site's own folders) - the homepage keeps its 4 videos.
#
# 1. Finds NEW videos ONLY from the channels in
#    /etc/chess-video-channels.json — the allowlist built 2026-10-03 from the channels of the 50
#    videos already in the library (channel ids read from each video's own watch page).
#    Source: each channel's public RSS feed of its "UULF" playlist (long-form uploads: YouTube
#    keeps Shorts and live streams out of it), no API key. Then, per candidate, its watch page
#    must say: same channel, playability OK, embeddable, family-safe (not age-restricted), not
#    live content, not upcoming, >= 61 s; youtube.com/shorts/<id> must redirect (303) — a Short
#    answers 200; and oEmbed must answer 200 (401 = embedding disabled, 404 = private/removed).
#    KIDS USE THE SITE: titles matching /etc/chess-video-blocklist.json (profanity, sexual, violent
#    words, "mate"/"mating" puns — real chess terms like "mate in 2" are allowed first) are skipped
#    before any request. A missing or malformed blocklist stops the run.
#    "New" = published since the last successful run (1 day overlap; window 7-21 days), not
#    already in the library, on the waiting list or rejected. At most 2 per channel per calendar week
#    (Sunday 00:00 AST on, counted from the library's createdAt plus the waiting list's foundAt, so a
#    re-run in the same week adds nothing beyond the 2), newest first.
#    The doc that approval inserts follows lila's Video case class: title = YouTube title, author = channel name,
#    targets = union of that channel's existing videos' targets, tags = existing library tags
#    that occur as whole words in the title, lang/ads/startTime as the rest of the library,
#    metadata from the RSS entry + watch page. Existing videos are NEVER modified.
# 2. Writes httpdocs/prcoffee/videos.json for /prcoffee/videos.js (homepage only): the 4 newest
#    videos by their REAL publish date, at most 1 per channel (relaxed only if needed to fill 4);
#    random fill if fewer than 4 have dates. Titles/channels/dates come from the verified cache
#    /var/lib/chess-video-refresh/verified.json (oEmbed + watch page per id; the 50 imported docs
#    were corrected from it on 2026-10-03 — their dates had been wrong for 49 of 50). Every strip
#    candidate must pass the title blocklist and a FRESH oEmbed + family-safe/embeddable check.
# 3. Downloads the strip's thumbnails (i.ytimg.com mqdefault, 320x180 JPEG, validated) into
#    httpdocs/prcoffee/video-thumbs/ — the homepage makes no third-party image requests. Keeps
#    only the current and previous strip's files (browsers may hold the old JSON for a while).
#
# Safety: lila must stay in DEV mode — in prod, VideoSheet syncs lichess.org's Google Sheet every
# 6 h and DELETES every video not in it (removeNotIn). The `video` collection is exported to
# /var/backups/chess-video-refresh/ before every insert (= every approval; last 20 kept). Inserts use
# $setOnInsert (an existing _id is never overwritten). YouTube requests are >= 1 s apart.
#
# Usage: chess-video-refresh.sh [--dry-run]                the (paused) weekly run: waiting list + strip
#        chess-video-refresh.sh --list-waiting             prints the waiting list (read-only, no request)
#        chess-video-refresh.sh --approve -- <id> [...]    the owner's approval (fresh YouTube check, then insert)
#        chess-video-refresh.sh --reject -- <id> [...]     the owner's no (never proposed again)
#   --dry-run   fetch and check everything, print what would go on the waiting list and the strip;
#               write nothing (no DB, no files, no cache)
#   Test hooks (BUTTON 234 tests only): CHESS_VIDEO_TEST_DB=test234<x> with CHESS_VIDEO_TEST_STATE=<absolute folder> use
#   that scratch database and folder (state, backups, web files, log) instead of lichess and the live paths; nothing is
#   checked on the live site.
#
# Undo an approval: the log lists every inserted id; db.video.deleteMany({_id: {$in: [...]}}). Undo BUTTON 234:
# PANIC-BUTTONS BUTTON 234.

set -euo pipefail

LOG=/var/log/chess-video-refresh.log

if [[ $EUID -ne 0 ]]; then
  echo "chess-video-refresh: run as root (it needs docker)" >&2
  exit 1
fi

exec 9>/run/lock/chess-video-refresh.lock
if ! flock -n 9; then
  case " $* " in
    *" --approve "*|*" --reject "*|*" --list-waiting "*)
      echo "chess-video-refresh: busy - a run holds /run/lock/chess-video-refresh.lock; nothing changed, try again in a few minutes" >&2
      exit 1;;
  esac
  echo "$(date -u +%FT%TZ) SKIP another run holds /run/lock/chess-video-refresh.lock" >> "$LOG"
  exit 0
fi

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, io, json, os, random, re, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

PROJECT = "/opt/chess/lila-docker"
CHANNELS_FILE = "/etc/chess-video-channels.json"
BLOCKLIST_FILE = "/etc/chess-video-blocklist.json"
# test hooks (BUTTON 234): a scratch database + folder, never the live ones
TEST_DB, TEST_STATE = os.environ.get("CHESS_VIDEO_TEST_DB", ""), os.environ.get("CHESS_VIDEO_TEST_STATE", "")
if bool(TEST_DB) != bool(TEST_STATE):
    sys.exit("chess-video-refresh: CHESS_VIDEO_TEST_DB and CHESS_VIDEO_TEST_STATE go together - nothing done")
TEST = bool(TEST_DB)
if TEST and (not re.fullmatch(r"test234[a-z0-9_]{0,20}", TEST_DB) or not os.path.isabs(TEST_STATE)
             or not os.path.isdir(TEST_STATE)
             or os.path.realpath(TEST_STATE).startswith(("/var/lib/", "/var/backups/", "/var/log/", "/var/www/"))):
    sys.exit("chess-video-refresh: refused test settings (database must be test234..., folder an existing absolute "
             "scratch folder) - nothing done")
DB = TEST_DB or "lichess"
LOG = f"{TEST_STATE}/chess-video-refresh.log" if TEST else "/var/log/chess-video-refresh.log"
STATE_DIR = f"{TEST_STATE}/state" if TEST else "/var/lib/chess-video-refresh"
VERIFIED = f"{STATE_DIR}/verified.json"
STATE = f"{STATE_DIR}/state.json"
PENDING = f"{STATE_DIR}/pending.json"     # the waiting list (BUTTON 234)
REJECTED = f"{STATE_DIR}/rejected.json"   # never proposed again (owner's no, or 28 days undecided)
PENDING_DAYS = 28
BACKUP_DIR = f"{TEST_STATE}/backups" if TEST else "/var/backups/chess-video-refresh"
KEEP_BACKUPS = 20
WEB_DIR = f"{TEST_STATE}/web/prcoffee" if TEST else "/var/www/vhosts/chesspuertoricocoffee.com/httpdocs/prcoffee"
THUMB_DIR = f"{WEB_DIR}/video-thumbs"
JSON_PATH = f"{WEB_DIR}/videos.json"
SITE_HOST = "chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"  # connect by IP, SNI on the real name, like the other health checks
STRIP_SIZE = 4
STRIP_PER_CHANNEL = 1
MAX_NEW_PER_CHANNEL = 2
MIN_SECONDS = 61
USER_AGENT = ("chesspuertoricocoffee.com-video-refresh/1.0 "
              "(+https://chesspuertoricocoffee.com; system@chesspuertoricocoffee.com)")
NS = {"a": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015",
      "media": "http://search.yahoo.com/mrss/"}
ID_RE = re.compile(r"[A-Za-z0-9_-]{11}")
LEVEL_TAGS = {"beginner", "intermediate", "advanced", "expert"}  # these mirror `targets`
UTC = dt.timezone.utc

ap = argparse.ArgumentParser(prog="chess-video-refresh.sh")
ap.add_argument("--dry-run", action="store_true", help="check everything, write nothing")
mode = ap.add_mutually_exclusive_group()
mode.add_argument("--list-waiting", action="store_true", help="print the videos that wait for approval")
mode.add_argument("--approve", action="store_true", help="add the waiting videos named after -- to the library")
mode.add_argument("--reject", action="store_true", help="drop the waiting videos named after --")
ap.add_argument("ids", nargs="*", help="video ids (11 characters), only with --approve / --reject")
args = ap.parse_args()
MODE = "approve" if args.approve else "reject" if args.reject else "list" if args.list_waiting else "run"
if MODE in ("approve", "reject"):
    if not args.ids or not all(ID_RE.fullmatch(v) for v in args.ids) or len(set(args.ids)) != len(args.ids):
        ap.error(f"--{MODE} needs one or more different video ids (11 characters each)")
if MODE != "run" and args.dry_run:
    ap.error("--dry-run goes only with the weekly run")
if MODE not in ("approve", "reject") and args.ids:
    ap.error("video ids go only with --approve or --reject")
DRY = args.dry_run
TAG = "DRY" if DRY else {"run": "RUN", "approve": "APPROVE", "reject": "REJECT", "list": "LIST"}[MODE]
now = dt.datetime.now(UTC).replace(microsecond=0)


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


def iso(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


# ---------------------------------------------------------------- HTTP (paced, no redirects on demand)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_last = [0.0]


def get(url, ua=USER_AGENT, follow=True, limit=4_000_000):
    """(status, body bytes) — status 0 on network errors. YouTube hosts are paced >= 1 s."""
    if "youtube.com" in url or "ytimg.com" in url:
        wait = 1.0 - (time.monotonic() - _last[0])
        if wait > 0:
            time.sleep(wait)
        _last[0] = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept-Language": "en"})
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=20) as r:
            return r.status, r.read(limit)
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception:
        return 0, b""


def watch_info(vid):
    st, body = get(f"https://www.youtube.com/watch?v={vid}")
    h = body.decode("utf-8", "replace")
    g = lambda p: (re.search(p, h) or [None, None])[1]
    return {
        "http": st,
        "channelId": g(r'itemprop="channelId" content="(UC[\w-]{22})"') or g(r'"channelId":"(UC[\w-]{22})"'),
        "publishDate": g(r'itemprop="datePublished" content="([^"]+)"') or g(r'"publishDate":"([^"]+)"'),
        "status": g(r'"playabilityStatus":\{"status":"([A-Z_]+)"'),
        "embeddable": g(r'"playableInEmbed":(true|false)'),
        "familySafe": g(r'"isFamilySafe":(true|false)'),  # false = age-restricted
        "live": g(r'"isLiveContent":(true|false)'),
        "upcoming": g(r'"isUpcoming":(true|false)'),
        "length": int(g(r'"lengthSeconds":"(\d+)"') or 0),
        "views": int(g(r'"viewCount":"(\d+)"') or 0),
    }


def oembed(vid):
    """(status, data): 200 = embeddable and public; 401 = embedding disabled; 404 = private/removed."""
    u = "https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(f"https://www.youtube.com/watch?v={vid}")
    st, body = get(u)
    try:
        return st, (json.loads(body) if st == 200 else None)
    except ValueError:
        return 0, None


def unsafe_now(vid, w=None):
    """None if YouTube says right now that the video may be shown here, else the reason.
    oEmbed covers embedding; age restriction only shows on the watch page (isFamilySafe)."""
    st, _ = oembed(vid)
    if st != 200:
        return f"oEmbed {st}"
    w = w or watch_info(vid)
    return (f"playability {w['status']}" if w["status"] != "OK" else
            "age-restricted" if w["familySafe"] != "true" else
            "not embeddable" if w["embeddable"] != "true" else None)


# ---------------------------------------------------------------- Mongo
def docker_mongo(*cmd, inp=None, timeout=180):
    return subprocess.run(["/usr/bin/docker", "compose", "exec", "-T", "mongodb", *cmd],
                          cwd=PROJECT, capture_output=True, text=True, timeout=timeout, input=inp)


def mongo(js):
    """Run JS in mongosh; the JS must print one line '@@JSON@@' + JSON.stringify(result)."""
    r = docker_mongo("mongosh", DB, "--quiet", "--eval", js)
    out = [l for l in r.stdout.splitlines() if l.startswith("@@JSON@@")]
    if r.returncode != 0 or not out:
        die(f"mongosh rc={r.returncode}: {(r.stderr or r.stdout).strip()[-400:]}")
    return json.loads(out[-1][len("@@JSON@@"):])


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data, mode=0o644, owner=None):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, mode)
    if owner:
        os.chown(tmp, *owner)
    os.replace(tmp, path)


# ---------------------------------------------------------------- inputs
channels = load_json(CHANNELS_FILE, None)
if not channels or not isinstance(channels.get("channels"), list):
    die(f"allowlist {CHANNELS_FILE} missing or malformed")
allow = {c["channelId"]: c for c in channels["channels"] if re.fullmatch(r"UC[\w-]{22}", c.get("channelId", ""))}
_bl = load_json(BLOCKLIST_FILE, None)
try:  # fail closed: no blocklist, no run (kids use the site)
    ALLOW_PHRASES = [re.compile(r"(?<!\w)" + p + r"(?!\w)", re.I) for p in _bl["allowChessPhrases"]]
    BLOCK = [(cat, w, re.compile(r"(?<!\w)" + w + r"(?!\w)", re.I)) for cat, ws in _bl["block"].items() for w in ws]
    assert BLOCK
except Exception as e:
    die(f"blocklist {BLOCKLIST_FILE} missing or malformed ({type(e).__name__}) — refusing to run")


def blocked(title):
    """'category:word' if the title must not be shown, else None. Chess phrases are removed first."""
    t = title or ""
    for a in ALLOW_PHRASES:
        t = a.sub(" ", t)
    for cat, w, rx in BLOCK:
        if rx.search(t):
            return f"{cat}:{w}"
    return "profanity:censored" if re.search(r"[A-Za-z]\*+[A-Za-z]", t) else None


verified = load_json(VERIFIED, {})
state = load_json(STATE, {})


# ---------------------------------------------------------------- the waiting list (BUTTON 234)
def load_queue():
    """(pending, rejected) - a file this script did not write stops everything: never guess."""
    try:
        p = load_json(PENDING, {"videos": []})
        r = load_json(REJECTED, {"rejected": {}})
    except (OSError, ValueError) as e:
        die(f"cannot read the waiting list ({type(e).__name__}) - look at {PENDING} / {REJECTED}; nothing changed")
    ok = (isinstance(p, dict) and isinstance(p.get("videos"), list) and isinstance(r, dict)
          and isinstance(r.get("rejected"), dict)
          and all(isinstance(x, dict) and ID_RE.fullmatch(str(x.get("id", ""))) and isinstance(x.get("doc"), dict)
                  and x["doc"].get("_id") == x["id"] and isinstance(x.get("verified"), dict)
                  and isinstance(x.get("foundAt"), str) for x in p["videos"]))
    if not ok:
        die(f"{PENDING} or {REJECTED} is not a file this script wrote - look at it; nothing changed")
    return p, r


pending, rejected_q = load_queue()
pending_ids = {x["id"] for x in pending["videos"]}


def mmss(s):
    return f"{int(s) // 60}:{int(s) % 60:02d}"


if MODE == "list":
    vids = sorted(pending["videos"], key=lambda x: x["foundAt"])
    if not vids:
        print("VIDEOS: none waiting for approval.")
        sys.exit(0)
    print(f"VIDEOS waiting for approval: {len(vids)} (each drops off by itself after {PENDING_DAYS} days)\n")
    for x in vids:
        d = x["doc"]
        print(f"  {x['id']}  {d['author']} - published {d['metadata']['publishedAt'][:10]}, "
              f"{mmss(d['metadata']['duration'])} long, found {x['foundAt'][:10]}")
        print(f"      {d['title']}")
        print(f"      https://www.youtube.com/watch?v={x['id']}")
    print("\n  Approve:  sudo chess-approve video <id> [<id> ...]"
          "\n  Reject:   sudo chess-approve reject-video <id> [<id> ...]")
    sys.exit(0)

if MODE == "reject":
    missing = [v for v in args.ids if v not in pending_ids]
    if missing:
        die(f"not on the waiting list: {missing} - nothing changed (see: sudo chess-approve)")
    for x in pending["videos"]:
        if x["id"] in args.ids:
            rejected_q["rejected"][x["id"]] = {"at": iso(now), "why": "rejected by the owner",
                                               "title": x["doc"]["title"], "channel": x["doc"]["author"]}
    os.makedirs(STATE_DIR, mode=0o750, exist_ok=True)
    write_json(REJECTED, rejected_q, mode=0o640)
    pending["videos"] = [x for x in pending["videos"] if x["id"] not in args.ids]
    write_json(PENDING, pending, mode=0o640)
    log(f"REJECTED {args.ids} - not published, never proposed again ({len(pending['videos'])} still waiting)")
    sys.exit(0)

lib = mongo(r"""print("@@JSON@@" + JSON.stringify(db.video.find({}, {title: 1, author: 1, targets: 1, tags: 1,
  lang: 1, createdAt: 1, "metadata.publishedAt": 1}).toArray()));""")
lib_ids = {v["_id"] for v in lib}


def backup_videos():
    os.makedirs(BACKUP_DIR, mode=0o750, exist_ok=True)
    r = docker_mongo("mongoexport", "--quiet", "--db", DB, "--collection", "video", "--jsonArray")
    try:
        n_backup = len(json.loads(r.stdout)) if r.returncode == 0 else -1
    except ValueError:
        n_backup = -1
    if n_backup != len(lib):
        die(f"backup of `video` failed or incomplete ({n_backup} vs {len(lib)}) — nothing written")
    bpath = f"{BACKUP_DIR}/video-{now:%Y%m%dT%H%M%SZ}.json"
    with open(bpath, "w", encoding="utf-8") as f:
        f.write(r.stdout)
    os.chmod(bpath, 0o640)
    for old in sorted(glob.glob(f"{BACKUP_DIR}/video-*.json"))[:-KEEP_BACKUPS]:
        os.remove(old)
    log(f"backup {bpath} ({n_backup} docs)")


def insert_docs(new_docs):
    inserted = []
    for i in range(0, len(new_docs), 10):  # small batches: --eval is one argv string (128 KB cap)
        res = mongo("const D = " + json.dumps(new_docs[i:i + 10]) + r""";
const ins = [];
for (const d of D) {
  // lila reads these as Scala Int; the 50 imported docs store int32, mongosh would write doubles
  d.startTime = NumberInt(d.startTime);
  d.targets = d.targets.map(t => NumberInt(t));
  for (const k of ["views", "likes", "duration"]) d.metadata[k] = NumberInt(d.metadata[k]);
  d.createdAt = new Date(d.createdAt);
  d.metadata.publishedAt = new Date(d.metadata.publishedAt);
  d.metadata.refreshedAt = new Date(d.metadata.refreshedAt);
  if (d.metadata.description === null) delete d.metadata.description;
  const r = db.video.updateOne({_id: d._id}, {$setOnInsert: d}, {upsert: true});
  if (r.upsertedCount) ins.push(d._id);
}
print("@@JSON@@" + JSON.stringify(ins));""")
        inserted += res
    return inserted


def fetch(path):
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "-o", "/dev/null", "-w", "%{http_code} %{content_type}",
                        "--resolve", f"{SITE_HOST}:443:{PROBE_IP}", f"https://{SITE_HOST}{path}"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip()


if MODE == "approve":
    missing = [v for v in args.ids if v not in pending_ids]
    if missing:
        die(f"not on the waiting list: {missing} - nothing changed (see: sudo chess-approve)")
    ok, refused = [], []
    for x in pending["videos"]:
        if x["id"] not in args.ids:
            continue
        bad = blocked(x["doc"]["title"])
        why = ("already in the library" if x["id"] in lib_ids else f"blocked title {bad}" if bad
               else unsafe_now(x["id"]))   # asked NOW: oEmbed 200, playable, family-safe, embeddable
        (refused if why else ok).append(f"{x['id']} ({why})" if why else x)
    if refused:
        log(f"NOT approved - they stay on the waiting list: {refused}", err=True)
    if not ok:
        sys.exit(1)
    backup_videos()
    docs = [dict(x["doc"], createdAt=iso(now), metadata=dict(x["doc"]["metadata"], refreshedAt=iso(now))) for x in ok]
    inserted = insert_docs(docs)
    for x in ok:
        if x["id"] in inserted:
            verified[x["id"]] = dict(x["verified"], checkedAt=iso(now))
    os.makedirs(STATE_DIR, mode=0o750, exist_ok=True)
    write_json(VERIFIED, verified, mode=0o640)
    pending["videos"] = [x for x in pending["videos"] if x["id"] not in inserted]
    write_json(PENDING, pending, mode=0o640)
    log(f"APPROVED {len(inserted)}/{len(ok)}: {inserted} - now in the /video library; the homepage strip changes only "
        f"at the next weekly refresh run ({len(pending['videos'])} still waiting)")
    if len(inserted) != len(ok):
        die(f"{len(ok) - len(inserted)} of them were already in the library (not inserted again)")
    if not TEST:
        bad = [f"/video/{v}" for v in inserted if not fetch(f"/video/{v}").startswith("200")]
        if bad:
            die(f"served-page check failed for {bad} (they are in the library)", code=2)
        log(f"OK /video pages of {inserted} answer 200")
    sys.exit(1 if refused else 0)
vocab = sorted({t for v in lib for t in v.get("tags", [])} - LEVEL_TAGS - {"community"}, key=len, reverse=True)
log(f"library {len(lib)} videos; allowlist {len(allow)} channels; verified cache {len(verified)}")

# verify library ids the cache does not know yet (2 requests each)
for v in lib:
    if v["_id"] in verified:
        continue
    (ost, o), w = oembed(v["_id"]), watch_info(v["_id"])
    if o and w["publishDate"]:
        verified[v["_id"]] = {"title": o["title"], "channel": o["author_name"], "channelId": w["channelId"],
                              "publishedAt": iso(parse_time(w["publishDate"])), "embedOk": True,
                              "familySafe": w["familySafe"] == "true", "checkedAt": iso(now)}
        log(f"verified {v['_id']} {o['author_name']!r} {w['publishDate'][:10]}")
    else:
        log(f"WARN cannot verify library video {v['_id']} (oEmbed {ost}, watch http {w['http']})")

# channel id of every library video -> targets / lang per channel
chan_targets, chan_lang = {}, {}
for v in lib:
    cid = (verified.get(v["_id"]) or {}).get("channelId")
    if cid:
        chan_targets.setdefault(cid, set()).update(v.get("targets") or [])
        chan_lang.setdefault(cid, v.get("lang") or "en")

# ---------------------------------------------------------------- 1. new videos from the allowlist
start = now - dt.timedelta(days=7)
if state.get("lastSuccess"):
    start = max(now - dt.timedelta(days=21), min(start, parse_time(state["lastSuccess"]) - dt.timedelta(days=1)))
log(f"window: published since {iso(start)}")
# weekly budget: Sunday 00:00 AST (UTC-4, no DST) of the current week
ast_now = now.astimezone(dt.timezone(dt.timedelta(hours=-4)))
week_start = (ast_now - dt.timedelta(days=(ast_now.weekday() + 1) % 7)).replace(hour=0, minute=0, second=0).astimezone(UTC)
added_this_week = {}
for v in lib:
    cid = (verified.get(v["_id"]) or {}).get("channelId")
    if cid and v.get("createdAt") and parse_time(v["createdAt"]) >= week_start:
        added_this_week[cid] = added_this_week.get(cid, 0) + 1
for x in pending["videos"]:   # found this week and still waiting: they use the same weekly budget
    cid = x["verified"].get("channelId")
    if cid and parse_time(x["foundAt"]) >= week_start:
        added_this_week[cid] = added_this_week.get(cid, 0) + 1
log(f"week since {iso(week_start)}: already added {sum(added_this_week.values())} ({ {allow[c]['name']: n for c, n in added_this_week.items() if c in allow} })")

new_docs = []
fresh_ok = set()  # passed every YouTube check in this run already
for cid, ch in allow.items():
    st, body = get(f"https://www.youtube.com/feeds/videos.xml?playlist_id=UULF{cid[2:]}")
    try:
        entries = ET.fromstring(body).findall("a:entry", NS) if st == 200 else None
    except ET.ParseError:
        entries = None
    if entries is None:
        log(f"WARN {ch['name']}: RSS failed (http {st}) — channel skipped this run")
        continue
    cands = []
    for e in entries:
        vid = e.findtext("yt:videoId", "", NS)
        pub = e.findtext("a:published", "", NS)
        link = (e.find("a:link", NS).get("href") if e.find("a:link", NS) is not None else "")
        title = " ".join(e.findtext("a:title", "", NS).split())
        if (not ID_RE.fullmatch(vid) or not pub or parse_time(pub) < start or vid in lib_ids
                or vid in pending_ids or vid in rejected_q["rejected"]):
            continue
        if "/shorts/" in link or "#shorts" in title.lower() or e.findtext("yt:channelId", cid, NS) != cid:
            continue
        cands.append((parse_time(pub), vid, title, e))
    cands.sort(reverse=True)
    accepted, skipped = [], []
    for pub, vid, title, e in cands:
        if len(accepted) >= MAX_NEW_PER_CHANNEL - added_this_week.get(cid, 0):
            break
        bad = blocked(title)
        if bad:  # decided on the title alone, before any request
            skipped.append(f"{vid} (blocked title {bad})")
            continue
        w = watch_info(vid)
        why = ("watch page unreadable" if not w["channelId"] else
               "other channel" if w["channelId"] != cid else
               f"playability {w['status']}" if w["status"] != "OK" else
               "age-restricted" if w["familySafe"] != "true" else
               "not embeddable" if w["embeddable"] != "true" else
               "live stream" if w["live"] == "true" else
               "upcoming" if w["upcoming"] == "true" else
               f"too short ({w['length']} s)" if w["length"] < MIN_SECONDS else None)
        if not why:
            sst, _ = get(f"https://www.youtube.com/shorts/{vid}", follow=False)
            why = "is a Short" if sst == 200 else None if sst in (301, 302, 303) else f"shorts check http {sst}"
        if not why:
            ost, _ = oembed(vid)
            why = None if ost == 200 else f"oEmbed {ost}"
        if why:
            skipped.append(f"{vid} ({why})")
            continue
        stats = e.find("media:group/media:community/media:statistics", NS)
        stars = e.find("media:group/media:community/media:starRating", NS)
        desc = (e.findtext("media:group/media:description", "", NS) or "").strip()
        low = title.lower()
        tags = sorted({t for t in vocab if re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", low)})
        doc = {"_id": vid, "title": title[:200], "author": ch["name"],
               "targets": sorted(chan_targets.get(cid) or {2, 3}), "tags": tags,
               "lang": chan_lang.get(cid, "en"), "ads": False, "startTime": 0,
               "metadata": {"views": min(2**31 - 1, int(stats.get("views", 0)) if stats is not None else w["views"]),
                            "likes": min(2**31 - 1, int(stars.get("count", 0)) if stars is not None else 0),
                            "description": desc[:1000] or None, "duration": w["length"],
                            "publishedAt": iso(pub), "refreshedAt": iso(now)},
               "createdAt": iso(now)}
        accepted.append({"id": vid, "foundAt": iso(now), "doc": doc,
                         "verified": {"title": title, "channel": ch["name"], "channelId": cid, "publishedAt": iso(pub),
                                      "embedOk": True, "familySafe": True, "checkedAt": iso(now)}})
    new_docs += accepted
    budget = max(0, MAX_NEW_PER_CHANNEL - added_this_week.get(cid, 0))
    log(f"{ch['name']}: {len(entries)} in feed, {len(cands)} new in window, week budget {budget} -> {len(accepted)} found"
        + (f" {[x['id'] for x in accepted]}" if accepted else "")
        + (f"; skipped {skipped}" if skipped else ""))

for x in new_docs:
    d = x["doc"]
    log(f"{'WOULD WAIT' if DRY else 'WAITING'} {d['_id']} {d['metadata']['publishedAt'][:10]} "
        f"{d['metadata']['duration']}s {d['author']!r} {d['title']!r} tags={d['tags']} targets={d['targets']}"
        " - NOT published: on the waiting list for the owner")
expired = [x for x in pending["videos"] if (now - parse_time(x["foundAt"])).days >= PENDING_DAYS]
if expired:
    log(f"{'WOULD DROP' if DRY else 'DROPPED'} from the waiting list after {PENDING_DAYS} days undecided "
        f"(never published): {[x['id'] for x in expired]}")

# ---------------------------------------------------------------- 2. pick the strip - from the LIBRARY only (approved videos)
pool = [vid for vid in lib_ids if vid in verified]
dated = sorted((v for v in pool if verified[v].get("publishedAt")),
               key=lambda v: verified[v]["publishedAt"], reverse=True)
undated = [v for v in pool if not verified[v].get("publishedAt")]
random.shuffle(undated)
order = dated + undated


def thumb_ok(data):
    if not data.startswith(b"\xff\xd8\xff") or len(data) < 2000:
        return False
    try:
        from PIL import Image
        return Image.open(io.BytesIO(data)).size == (320, 180)
    except ImportError:
        return True
    except Exception:
        return False


thumbs = {}  # vid -> bytes (downloaded, not yet written) or True (already on disk)


def have_thumb(vid):
    if vid in thumbs:
        return True
    path = f"{THUMB_DIR}/{vid}.jpg"
    if os.path.exists(path):
        with open(path, "rb") as f:
            if thumb_ok(f.read()):
                thumbs[vid] = True
                return True
    st, data = get(f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg", limit=500_000)
    if st == 200 and thumb_ok(data):
        thumbs[vid] = data
        return True
    log(f"WARN thumbnail for {vid} failed (http {st}) — not shown")
    return False


rejected = {}  # vid -> reason; a strip candidate is checked at most once per run


def showable(vid):
    """Kids-safe gate for the homepage: blocklist on the verified title, then YouTube asked NOW."""
    if vid not in rejected:
        why = blocked(verified[vid].get("title"))
        why = f"blocked title {why}" if why else (None if vid in fresh_ok else unsafe_now(vid))
        if why:
            log(f"strip skips {vid} ({why}) {verified[vid].get('title')!r}")
        rejected[vid] = why
    return rejected[vid] is None


strip, per_channel = [], {}
for relax in (False, True):  # 2nd pass only if 1-per-channel cannot fill the strip
    for vid in order:
        if len(strip) >= STRIP_SIZE:
            break
        cid = verified[vid].get("channelId")
        if vid in strip or (not relax and per_channel.get(cid, 0) >= STRIP_PER_CHANNEL):
            continue
        if showable(vid) and have_thumb(vid):
            strip.append(vid)
            per_channel[cid] = per_channel.get(cid, 0) + 1


def label(s):
    t = parse_time(s).astimezone(dt.timezone(dt.timedelta(hours=-4)))  # AST, no DST
    return f"{t:%b} {t.day}, {t.year}"


payload = {"generated": iso(now), "source": "chess-video-refresh.sh", "videos": [
    {"id": v, "url": f"/video/{v}", "thumb": f"/prcoffee/video-thumbs/{v}.jpg",
     "title": verified[v]["title"], "channel": verified[v]["channel"],
     "date": (verified[v].get("publishedAt") or "")[:10],
     "dateLabel": label(verified[v]["publishedAt"]) if verified[v].get("publishedAt") else ""}
    for v in strip]}
log("strip: " + "; ".join(f"{p['id']} {p['date']} {p['channel']!r} {p['title'][:50]!r}" for p in payload["videos"]))
if len(strip) < STRIP_SIZE:
    log(f"WARN strip has only {len(strip)} videos", err=not DRY)

if DRY:
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    sys.exit(0)

# ---------------------------------------------------------------- write: backup, insert, files
os.makedirs(STATE_DIR, mode=0o750, exist_ok=True)
if new_docs or expired:   # the waiting list - nothing goes into lila's library here (BUTTON 234)
    for x in expired:
        rejected_q["rejected"][x["id"]] = {"at": iso(now), "why": f"{PENDING_DAYS} days on the waiting list, undecided",
                                           "title": x["doc"]["title"], "channel": x["doc"]["author"]}
    if expired:
        write_json(REJECTED, rejected_q, mode=0o640)
    gone = {x["id"] for x in expired}
    pending["videos"] = [x for x in pending["videos"] if x["id"] not in gone] + new_docs
    write_json(PENDING, pending, mode=0o640)
    log(f"waiting list: {len(pending['videos'])} videos wait for the owner (+{len(new_docs)} new"
        + (f", -{len(expired)} dropped" if expired else "") + ") - see: sudo chess-approve")

write_json(VERIFIED, verified, mode=0o640)

st_web = os.stat(WEB_DIR)
owner = (st_web.st_uid, st_web.st_gid)
os.makedirs(THUMB_DIR, exist_ok=True)
os.chown(THUMB_DIR, *owner)
os.chmod(THUMB_DIR, 0o755)
for vid, data in thumbs.items():
    if data is True:
        continue
    tmp = f"{THUMB_DIR}/.{vid}.jpg.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.chown(tmp, *owner)
    os.replace(tmp, f"{THUMB_DIR}/{vid}.jpg")
write_json(JSON_PATH, payload, owner=owner)

keep = set(strip) | set(state.get("stripIds") or [])
for path in glob.glob(f"{THUMB_DIR}/*.jpg"):
    if os.path.basename(path)[:-4] not in keep:
        os.remove(path)
log(f"wrote {JSON_PATH} ({len(strip)} videos), thumbnails kept: {sorted(keep)}")

# ---------------------------------------------------------------- verify on the wire (fetch() is defined above)
if TEST:
    write_json(STATE, {"lastSuccess": iso(now), "stripIds": strip, "prevStripIds": state.get("stripIds") or []}, mode=0o640)
    log(f"OK (test mode: nothing checked on the live site) {len(strip)} strip videos, {len(pending['videos'])} waiting")
    sys.exit(0)
bad = []
if not fetch("/prcoffee/videos.json").startswith("200"):
    bad.append("/prcoffee/videos.json")
for p in payload["videos"]:
    if not fetch(p["thumb"]).startswith("200 image/jpeg"):
        bad.append(p["thumb"])
    if not fetch(p["url"]).startswith("200"):
        bad.append(p["url"])
write_json(STATE, {"lastSuccess": iso(now) if not bad else state.get("lastSuccess"),
                   "stripIds": strip, "prevStripIds": state.get("stripIds") or []}, mode=0o640)
if bad:
    die(f"served-file check failed for {bad}", code=2)
log(f"OK videos.json + {len(strip)} thumbnails + {len(strip)} /video pages all 200; "
    f"{len(pending['videos'])} videos wait for approval")
PY
