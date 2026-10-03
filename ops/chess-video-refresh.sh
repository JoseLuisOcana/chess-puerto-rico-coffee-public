#!/bin/bash
# chess-video-refresh.sh — weekly refresh of the homepage "🎥 Chess Videos" strip on chesspuertoricocoffee.com
#
# Added 2026-10-03. Cron: /etc/cron.d/chess-video-refresh (Sun 07:00 AST — the server TZ is
# America/Puerto_Rico, no DST). Log: /var/log/chess-video-refresh.log.
#
# 1. Adds NEW videos to lila's own library (Mongo `video` collection) ONLY from the channels in
#    /etc/chess-video-channels.json — the allowlist built 2026-10-03 from the channels of the 50
#    videos already in the library (channel ids read from each video's own watch page).
#    Source: each channel's public RSS feed of its "UULF" playlist (long-form uploads: YouTube
#    keeps Shorts and live streams out of it), no API key. Then, per candidate, its watch page
#    must say: same channel, playability OK, embeddable, not live content, not upcoming,
#    >= 61 s; and youtube.com/shorts/<id> must redirect (303) — a Short answers 200.
#    "New" = published since the last successful run (1 day overlap; window 7-21 days), not
#    already in the library. At most 5 per channel per calendar week (Sunday 00:00 AST on, counted
#    from the library's createdAt, so a re-run in the same week adds nothing beyond the 5), newest first.
#    Doc fields follow lila's Video case class: title = YouTube title, author = channel name,
#    targets = union of that channel's existing videos' targets, tags = existing library tags
#    that occur as whole words in the title, lang/ads/startTime as the rest of the library,
#    metadata from the RSS entry + watch page. Existing videos are NEVER modified.
# 2. Writes httpdocs/prcoffee/videos.json for /prcoffee/videos.js (homepage only): the 4 newest
#    videos by their REAL publish date, at most 1 per channel (relaxed only if needed to fill 4);
#    random fill if fewer than 4 have dates. Titles/channels/dates come from the verified cache
#    /var/lib/chess-video-refresh/verified.json, not from the library docs: on 2026-10-03 the
#    stored metadata.publishedAt was wrong for 49 of the 50 imported videos and 11 `author`
#    fields name a presenter or another channel. Unknown ids are verified via oEmbed + watch page.
# 3. Downloads the strip's thumbnails (i.ytimg.com mqdefault, 320x180 JPEG, validated) into
#    httpdocs/prcoffee/video-thumbs/ — the homepage makes no third-party image requests. Keeps
#    only the current and previous strip's files (browsers may hold the old JSON for a while).
#
# Safety: lila must stay in DEV mode — in prod, VideoSheet syncs lichess.org's Google Sheet every
# 6 h and DELETES every video not in it (removeNotIn). The `video` collection is exported to
# /var/backups/chess-video-refresh/ before every insert (last 20 kept). Inserts use
# $setOnInsert (an existing _id is never overwritten). YouTube requests are >= 1 s apart.
#
# Usage: chess-video-refresh.sh [--dry-run]
#   --dry-run   fetch and check everything, print what would be inserted and the strip;
#               write nothing (no DB, no files, no cache)
#
# Undo an insert: the log lists every inserted id; db.video.deleteMany({_id: {$in: [...]}}).

set -euo pipefail

LOG=/var/log/chess-video-refresh.log

if [[ $EUID -ne 0 ]]; then
  echo "chess-video-refresh: run as root (it needs docker)" >&2
  exit 1
fi

exec 9>/run/lock/chess-video-refresh.lock
if ! flock -n 9; then
  echo "$(date -u +%FT%TZ) SKIP another run holds /run/lock/chess-video-refresh.lock" >> "$LOG"
  exit 0
fi

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, io, json, os, random, re, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

LOG = "/var/log/chess-video-refresh.log"
PROJECT = "/opt/chess/lila-docker"
CHANNELS_FILE = "/etc/chess-video-channels.json"
STATE_DIR = "/var/lib/chess-video-refresh"
VERIFIED = f"{STATE_DIR}/verified.json"
STATE = f"{STATE_DIR}/state.json"
BACKUP_DIR = "/var/backups/chess-video-refresh"
KEEP_BACKUPS = 20
WEB_DIR = "/var/www/vhosts/chesspuertoricocoffee.com/httpdocs/prcoffee"
THUMB_DIR = f"{WEB_DIR}/video-thumbs"
JSON_PATH = f"{WEB_DIR}/videos.json"
SITE_HOST = "chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"  # connect by IP, SNI on the real name, like the other health checks
STRIP_SIZE = 4
STRIP_PER_CHANNEL = 1
MAX_NEW_PER_CHANNEL = 5
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
args = ap.parse_args()
DRY = args.dry_run
TAG = "DRY" if DRY else "RUN"
now = dt.datetime.now(UTC).replace(microsecond=0)


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
        "live": g(r'"isLiveContent":(true|false)'),
        "upcoming": g(r'"isUpcoming":(true|false)'),
        "length": int(g(r'"lengthSeconds":"(\d+)"') or 0),
        "views": int(g(r'"viewCount":"(\d+)"') or 0),
    }


def oembed(vid):
    u = "https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(f"https://www.youtube.com/watch?v={vid}")
    st, body = get(u)
    return json.loads(body) if st == 200 else None


# ---------------------------------------------------------------- Mongo
def docker_mongo(*cmd, inp=None, timeout=180):
    return subprocess.run(["/usr/bin/docker", "compose", "exec", "-T", "mongodb", *cmd],
                          cwd=PROJECT, capture_output=True, text=True, timeout=timeout, input=inp)


def mongo(js):
    """Run JS in mongosh; the JS must print one line '@@JSON@@' + JSON.stringify(result)."""
    r = docker_mongo("mongosh", "lichess", "--quiet", "--eval", js)
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
verified = load_json(VERIFIED, {})
state = load_json(STATE, {})

lib = mongo(r"""print("@@JSON@@" + JSON.stringify(db.video.find({}, {title: 1, author: 1, targets: 1, tags: 1,
  lang: 1, createdAt: 1, "metadata.publishedAt": 1}).toArray()));""")
lib_ids = {v["_id"] for v in lib}
vocab = sorted({t for v in lib for t in v.get("tags", [])} - LEVEL_TAGS - {"community"}, key=len, reverse=True)
log(f"library {len(lib)} videos; allowlist {len(allow)} channels; verified cache {len(verified)}")

# verify library ids the cache does not know yet (2 requests each)
for v in lib:
    if v["_id"] in verified:
        continue
    o, w = oembed(v["_id"]), watch_info(v["_id"])
    if o and w["publishDate"]:
        verified[v["_id"]] = {"title": o["title"], "channel": o["author_name"], "channelId": w["channelId"],
                              "publishedAt": iso(parse_time(w["publishDate"])), "checkedAt": iso(now)}
        log(f"verified {v['_id']} {o['author_name']!r} {w['publishDate'][:10]}")
    else:
        log(f"WARN cannot verify library video {v['_id']} (oEmbed {'ok' if o else 'failed'}, watch http {w['http']})")

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
log(f"week since {iso(week_start)}: already added {sum(added_this_week.values())} ({ {allow[c]['name']: n for c, n in added_this_week.items() if c in allow} })")

new_docs = []
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
        if not ID_RE.fullmatch(vid) or not pub or parse_time(pub) < start or vid in lib_ids:
            continue
        if "/shorts/" in link or "#shorts" in title.lower() or e.findtext("yt:channelId", cid, NS) != cid:
            continue
        cands.append((parse_time(pub), vid, title, e))
    cands.sort(reverse=True)
    accepted, skipped = [], []
    for pub, vid, title, e in cands:
        if len(accepted) >= MAX_NEW_PER_CHANNEL - added_this_week.get(cid, 0):
            break
        w = watch_info(vid)
        why = ("watch page unreadable" if not w["channelId"] else
               "other channel" if w["channelId"] != cid else
               f"playability {w['status']}" if w["status"] != "OK" else
               "not embeddable" if w["embeddable"] != "true" else
               "live stream" if w["live"] == "true" else
               "upcoming" if w["upcoming"] == "true" else
               f"too short ({w['length']} s)" if w["length"] < MIN_SECONDS else None)
        if not why:
            sst, _ = get(f"https://www.youtube.com/shorts/{vid}", follow=False)
            why = "is a Short" if sst == 200 else None if sst in (301, 302, 303) else f"shorts check http {sst}"
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
        accepted.append(doc)
        verified[vid] = {"title": title, "channel": ch["name"], "channelId": cid,
                         "publishedAt": iso(pub), "checkedAt": iso(now)}
    new_docs += accepted
    budget = max(0, MAX_NEW_PER_CHANNEL - added_this_week.get(cid, 0))
    log(f"{ch['name']}: {len(entries)} in feed, {len(cands)} new in window, week budget {budget} -> {len(accepted)} accepted"
        + (f" {[d['_id'] for d in accepted]}" if accepted else "")
        + (f"; skipped {skipped}" if skipped else ""))

for d in new_docs:
    log(f"{'WOULD INSERT' if DRY else 'INSERT'} {d['_id']} {d['metadata']['publishedAt'][:10]} "
        f"{d['metadata']['duration']}s {d['author']!r} {d['title']!r} tags={d['tags']} targets={d['targets']}")

# ---------------------------------------------------------------- 2. pick the strip
pool = [vid for vid in lib_ids | {d["_id"] for d in new_docs} if vid in verified]
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


strip, per_channel = [], {}
for relax in (False, True):  # 2nd pass only if 1-per-channel cannot fill the strip
    for vid in order:
        if len(strip) >= STRIP_SIZE:
            break
        cid = verified[vid].get("channelId")
        if vid in strip or (not relax and per_channel.get(cid, 0) >= STRIP_PER_CHANNEL):
            continue
        if have_thumb(vid):
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
if new_docs:
    os.makedirs(BACKUP_DIR, mode=0o750, exist_ok=True)
    r = docker_mongo("mongoexport", "--quiet", "--db", "lichess", "--collection", "video", "--jsonArray")
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
    log(f"INSERTED {len(inserted)}/{len(new_docs)}: {inserted}")

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

# ---------------------------------------------------------------- verify on the wire
def fetch(path):
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "-o", "/dev/null", "-w", "%{http_code} %{content_type}",
                        "--resolve", f"{SITE_HOST}:443:{PROBE_IP}", f"https://{SITE_HOST}{path}"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip()


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
log(f"OK videos.json + {len(strip)} thumbnails + {len(strip)} /video pages all 200")
PY
