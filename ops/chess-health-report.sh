#!/bin/bash
# chess-health-report.sh — weekly health report for chesspuertoricocoffee.com, e-mailed to system@chesspuertoricocoffee.com
#
# Added 2026-10-03. Cron: /etc/cron.d/chess-health-report (Mondays 09:00 AST — the server TZ is America/Puerto_Rico,
# no DST). Log: /var/log/chess-health-report.log (one line per run). Read-only: it changes nothing on the server.
#
# Sends through IONOS SMTP (smtp.ionos.com:587, STARTTLS) as the system@ mailbox, reading the credentials at run time
# from /etc/chess-contact.env (root 0600, shared with chess-contact.service). The password is never copied or printed.
# If the IONOS password changes, that file (and lila's .env MAILER_PASSWORD) must be updated — see CLAUDE.md.
#
# Subject starts with ✅ when every check passes, ⚠️ when any check needs attention. Checks and thresholds:
#   - last nightly mongodump: log line OK + verified=yes, archive present with the logged size, younger than 26 h
#   - disk free on /: warn under 15 % or under 30 GB
#   - TLS certificate of every hostname on the server (connect by IP with SNI, full chain + hostname check): warn under 21 days
#   - last REAL run of each cron (dry-runs are ignored): result, and age against its schedule
#       puzzle recycle 04:15 daily (26 h), mongodump 03:30 daily (26 h), auto-feed Mon+Thu 08:00 (4.5 days),
#       video refresh Sun 07:00 (8 days), bgjobs cleanup Sun 04:45 (8 days)
#   - lila-docker containers: any not running, unhealthy, or with RestartCount > 0 — except EXPECTED_STOPPED below:
#     elasticvue (Elasticsearch web UI) and mailpit (dev mail catcher; real mail goes through IONOS) are dev tools in the
#     active `search`/`email` profiles that have been stopped on purpose since 2026-09-13; they are listed, not flagged.
#   - last 7 days of lila error.log (ERROR lines) and nginx error.log (emerg/alert/crit). Two KNOWN-BENIGN nginx patterns
#     are counted separately and do not warn: "open() …/logs/proxy_* failed (13: Permission denied)" (a non-root nginx
#     config test every midnight, ~252 lines/day since at least 2026-09-28), client-side TLS aborts ("SSL_do_handshake()",
#     "SSL_read()" or "SSL_write() failed"), and emerg lines about a config file outside /etc/nginx (someone running
#     `nginx -t` on a scratch copy). Anything else at emerg/alert/crit warns.
#   - RAM and swap: warn when available RAM < 10 % or swap > 50 % used
#
# Usage: chess-health-report.sh [--dry-run] [--test]
#   --dry-run   print the report, send nothing
#   --test      send, with "[test]" at the end of the subject

# (Public copy: the other sites hosted on this server are not listed; otherwise identical to the deployed script.)
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "chess-health-report: run as root" >&2; exit 1; fi
exec 9>/run/lock/chess-health-report.lock
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP another run holds the lock" >> /var/log/chess-health-report.log; exit 0; }

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, gzip, json, os, re, shutil, smtplib, socket, ssl, subprocess, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

LOG = "/var/log/chess-health-report.log"
PROJECT = "/opt/chess/lila-docker"
ENV_FILE = "/etc/chess-contact.env"
TO = "system@chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"   # connect by IP + SNI (one hostname resolves to a loopback address locally)
HOSTS = ["chesspuertoricocoffee.com", "www.chesspuertoricocoffee.com"]  # public copy: the other sites on this server are not listed
CERT_WARN_DAYS = 21
EXPECTED_STOPPED = {"elasticvue": "Elasticsearch web UI, dev tool", "mailpit": "dev mail catcher; real mail goes via IONOS"}
AST = dt.timezone(dt.timedelta(hours=-4))   # America/Puerto_Rico, no DST
UTC = dt.timezone.utc

ap = argparse.ArgumentParser(prog="chess-health-report.sh")
ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--test", action="store_true")
args = ap.parse_args()
now = dt.datetime.now(UTC)
issues, sections = [], []


def warn(msg):
    issues.append(msg)
    return "⚠️ "


def age_txt(t):
    s = (now - t).total_seconds()
    return f"{s/3600:.0f} h ago" if s < 172800 else f"{s/86400:.1f} days ago"


def tail_lines(path, n=4000):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 2_000_000))
            return f.read().decode("utf-8", "replace").splitlines()[-n:]
    except FileNotFoundError:
        return []


def iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


# ---------------------------------------------------------------- 1. mongodump
lines = [l for l in tail_lines("/var/log/chess-mongodump.log") if re.match(r"\d{4}-\d\d-\d\dT", l)]
out = ["BACKUP (nightly mongodump, 03:30)"]
if not lines:
    out.append(warn("no mongodump log line found") + "no run logged")
else:
    last = lines[-1]; t = iso(last.split()[0])
    m = re.search(r" OK (\S+) size=(\d+) lichess_collections=(\d+) verified=(\w+)", last)
    if not m:
        out.append(warn("last mongodump did not succeed") + f"last run {t.astimezone(AST):%a %b %d %H:%M} AST: {last[21:140]}")
    else:
        path, size, colls, ver = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        flag = ""
        if ver != "yes": flag = warn("last mongodump not verified")
        if (now - t).total_seconds() > 26 * 3600: flag = warn(f"last mongodump is {age_txt(t)}")
        if not os.path.exists(path) or os.path.getsize(path) != size: flag = warn("mongodump archive missing or size changed")
        out.append(f"{flag}{t.astimezone(AST):%a %b %d %H:%M} AST ({age_txt(t)}), {size/1048576:.1f} MB, "
                   f"{colls} collections, verified={ver}, {os.path.basename(path)}")
sections.append(out)

# ---------------------------------------------------------------- 2. disk
du = shutil.disk_usage("/"); pct = 100 * du.free / du.total
flag = warn(f"disk free {pct:.0f} %") if pct < 15 or du.free < 30e9 else ""
sections.append(["DISK", f"{flag}/ : {du.free/1e9:.0f} GB free of {du.total/1e9:.0f} GB ({pct:.0f} % free)"])

# ---------------------------------------------------------------- 3. TLS certificates
out = [f"TLS CERTIFICATES (warn under {CERT_WARN_DAYS} days)"]
ctx = ssl.create_default_context()
for h in HOSTS:
    try:
        with socket.create_connection((PROBE_IP, 443), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=h) as tls:
                end = dt.datetime.fromtimestamp(ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"]), UTC)
        days = (end - now).days
        flag = warn(f"{h} certificate expires in {days} days") if days < CERT_WARN_DAYS else ""
        out.append(f"{flag}{h:44} {days:3d} days (until {end:%b %d %Y})")
    except Exception as e:
        out.append(warn(f"{h} TLS check failed") + f"{h:44} FAILED: {type(e).__name__}: {str(e)[:80]}")
sections.append(out)

# ---------------------------------------------------------------- 4. crons (last REAL run)
out = ["CRON JOBS (last real run; dry-runs ignored)"]


def cron_row(name, t, status, ok, max_age_h):
    flag = ""
    if t is None:
        flag = warn(f"{name}: no run logged"); return f"{flag}{name:22} never ran"
    if not ok: flag = warn(f"{name}: {status}")
    elif (now - t).total_seconds() > max_age_h * 3600: flag = warn(f"{name}: last run {age_txt(t)} (overdue)")
    return f"{flag}{name:22} {t.astimezone(AST):%a %b %d %H:%M} AST ({age_txt(t)}) — {status}"


# puzzle recycle: one line per run, "ISO recycled=N ..."
l = [x for x in tail_lines("/var/log/chess-daily-puzzle-recycle.log") if re.match(r"\d{4}-\d\d-\d\dT.* recycled=", x)]
out.append(cron_row("daily puzzle recycle", iso(l[-1].split()[0]) if l else None,
                    (re.search(r"recycled=\d+", l[-1]).group(0) if l else ""), True, 26))
# mongodump (same log as section 1)
l = lines
out.append(cron_row("nightly mongodump", iso(l[-1].split()[0]) if l else None,
                    ("OK" if l and " OK " in l[-1] else "FAIL"), bool(l and " OK " in l[-1]), 26))


def tagged_run(path, max_age_h, name, ok_rx, fail_rx):
    rl = [x for x in tail_lines(path) if re.match(r"\d{4}-\d\d-\d\dT\S+ RUN ", x)]
    if not rl:
        return cron_row(name, None, "", False, max_age_h)
    t_end = iso(rl[-1].split()[0])
    run = [x for x in rl if (t_end - iso(x.split()[0])).total_seconds() <= 900]   # lines of that last run
    fail = [x for x in run if re.search(fail_rx, x)]
    okl = [x for x in run if re.search(ok_rx, x)]
    status = (fail[-1].split(" RUN ", 1)[1][:110] if fail else okl[-1].split(" RUN ", 1)[1][:110] if okl else "no result line")
    return cron_row(name, t_end, status, not fail and bool(okl), max_age_h)


out.append(tagged_run("/var/log/chess-auto-feed.log", 4.5 * 24, "news auto-feed", r" RUN (OK|SKIP) ", r" RUN ERROR "))
out.append(tagged_run("/var/log/chess-video-refresh.log", 8 * 24, "video refresh", r" RUN OK ", r" RUN ERROR "))
# bgjobs: "YYYY-MM-DD HH:MM:SS AST ..." local time; dry-run lines carry "[dry-run] "
bl = [x for x in tail_lines("/var/log/chess-bgjobs-cleanup.log") if re.match(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", x) and "[dry-run]" not in x]
end = [x for x in bl if re.search(r" (done:|SKIP:)", x)]
if end:
    t = dt.datetime.strptime(end[-1][:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST)
    st = end[-1][24:].strip()
    out.append(cron_row("bgjobs cleanup", t, st[:110], st.startswith("done:"), 8 * 24))
else:
    out.append(cron_row("bgjobs cleanup", None, "", False, 8 * 24))
sections.append(out)

# ---------------------------------------------------------------- 5. containers
out = ["CONTAINERS (lila-docker)"]
ids = subprocess.run(["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=lila-docker"],
                     capture_output=True, text=True).stdout.split()
bad = 0; expected_down = []
for c in json.loads(subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True).stdout or "[]"):
    name = c["Name"].lstrip("/").replace("lila-docker-", ""); stt = c["State"]
    health = (stt.get("Health") or {}).get("Status", "-"); rc = c.get("RestartCount", 0)
    if name.rsplit("-", 1)[0] in EXPECTED_STOPPED and stt["Status"] == "exited" and rc == 0:
        expected_down.append(f"{name:24} stopped on purpose ({EXPECTED_STOPPED[name.rsplit('-', 1)[0]]})"); continue
    if stt["Status"] != "running" or health == "unhealthy" or rc > 0:
        bad += 1
        out.append(warn(f"container {name}: {stt['Status']}, health {health}, restarts {rc}") +
                   f"{name:24} {stt['Status']}, health {health}, restarts {rc}")
out.insert(1, f"{len(ids)} containers: {len(ids) - bad - len(expected_down)} running with 0 restarts" + ("" if bad else " — all OK"))
out += [f"  {x}" for x in expected_down]
sections.append(out)

# ---------------------------------------------------------------- 6. errors, last 7 days
since = now - dt.timedelta(days=7)


def read_all(pattern):
    for p in sorted(glob.glob(pattern)):
        try:
            op = gzip.open if p.endswith(".gz") else open
            with op(p, "rt", errors="replace") as f:
                yield from f
        except OSError:
            continue


lila_err = []
for l in read_all(f"{PROJECT}/repos/lila/logs/error.log*"):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", l)
    if m and " ERROR " in l and dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=UTC) >= since:
        lila_err.append(re.sub(r"^\S+ \S+ ERROR\s+", "", l.strip())[:90])
counts = {"emerg": 0, "alert": 0, "crit": 0, "error": 0}; benign_perm = benign_tls = benign_test = 0; other = []
since_ng = since.astimezone(AST).strftime("%Y/%m/%d %H:%M:%S")
for l in read_all("/var/log/nginx/error.log*"):
    if l[:19] < since_ng or not re.match(r"\d{4}/\d\d/\d\d", l):
        continue
    m = re.search(r"\[(emerg|alert|crit|error)\]", l)
    if not m: continue
    lvl = m.group(1)
    if lvl in ("emerg", "crit") and "(13: Permission denied)" in l and "/logs/proxy_" in l: benign_perm += 1; continue
    if lvl == "crit" and re.search(r"SSL_(do_handshake|read|write)\(\) failed", l): benign_tls += 1; continue
    if lvl == "emerg" and re.search(r" in (?!/etc/nginx/)/\S+:\d+", l): benign_test += 1; continue
    counts[lvl] += 1
    if lvl != "error": other.append(re.sub(r"^\S+ \S+ ", "", l.strip())[:110])
out = ["ERRORS (last 7 days)"]
flag = warn(f"{len(lila_err)} lila ERROR lines") if lila_err else ""
out.append(f"{flag}lila error.log: {len(lila_err)} ERROR lines")
for msg, n in sorted({m: lila_err.count(m) for m in lila_err}.items(), key=lambda kv: -kv[1])[:3]:
    out.append(f"    {n} × {msg}")
unexpected = counts["emerg"] + counts["alert"] + counts["crit"]
flag = warn(f"{unexpected} unexpected nginx emerg/alert/crit lines") if unexpected else ""
out.append(f"{flag}nginx error.log: {unexpected} unexpected emerg/alert/crit, {counts['error']} [error]")
for msg in other[-3:]:
    out.append(f"    {msg}")
out.append(f"    known benign (not counted): {benign_perm} midnight non-root config-test lines, {benign_tls} client TLS aborts, "
           f"{benign_test} config tests of files outside /etc/nginx")
sections.append(out)

# ---------------------------------------------------------------- 7. RAM / swap
mi = {k: int(v.split()[0]) for k, v in (l.split(":", 1) for l in open("/proc/meminfo"))}
avail = 100 * mi["MemAvailable"] / mi["MemTotal"]
swap_used = mi["SwapTotal"] - mi["SwapFree"]; swap_pct = 100 * swap_used / mi["SwapTotal"] if mi["SwapTotal"] else 0
out = ["MEMORY"]
out.append((warn(f"available RAM {avail:.0f} %") if avail < 10 else "") +
           f"RAM: {mi['MemAvailable']/1048576:.1f} GB available of {mi['MemTotal']/1048576:.1f} GB ({avail:.0f} %)")
out.append((warn(f"swap {swap_pct:.0f} % used") if swap_pct > 50 else "") +
           f"swap: {swap_used/1048576:.2f} GB used of {mi['SwapTotal']/1048576:.1f} GB ({swap_pct:.0f} %), swappiness {open('/proc/sys/vm/swappiness').read().strip()}")
load = open("/proc/loadavg").read().split()[:3]
out.append(f"load average {' '.join(load)} on {os.cpu_count()} CPUs, up {float(open('/proc/uptime').read().split()[0])/86400:.1f} days")
sections.append(out)

# ---------------------------------------------------------------- compose + send
ok = not issues
subject = (f"{'✅' if ok else '⚠️'} Chess Puerto Rico Coffee — weekly health report, {now.astimezone(AST):%a %b %d, %Y}"
           + ("" if ok else f" — {len(issues)} item(s) need attention") + (" [test]" if args.test else ""))
body = [f"Weekly health report for chesspuertoricocoffee.com — {now.astimezone(AST):%Y-%m-%d %H:%M} AST",
        "Everything checked is OK." if ok else "NEEDS ATTENTION:"]
body += [f"  - {i}" for i in issues]
for sec in sections:
    body += ["", sec[0], "-" * len(sec[0])] + [f"  {l}" for l in sec[1:]]
body += ["", "Generated by /usr/local/bin/chess-health-report.sh (read-only). Thresholds and details: the script header."]
text = "\n".join(body) + "\n"

if args.dry_run:
    print("Subject:", subject); print(); print(text)
    with open(LOG, "a") as f: f.write(f"{now:%Y-%m-%dT%H:%M:%SZ} DRY {'OK' if ok else 'WARN'} issues={len(issues)}\n")
    sys.exit(0)

env = {}
for l in open(ENV_FILE):
    l = l.strip()
    if l and not l.startswith("#") and "=" in l:
        k, v = l.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
msg = EmailMessage()
msg["Subject"] = subject; msg["From"] = f"Chess Puerto Rico Coffee <{env['SMTP_USER']}>"; msg["To"] = TO
msg["Date"] = formatdate(localtime=True); msg["Message-ID"] = make_msgid(domain="chesspuertoricocoffee.com")
msg.set_content(text)
try:
    with smtplib.SMTP(env["SMTP_HOST"], int(env.get("SMTP_PORT", 587)), timeout=30) as s:
        s.starttls(context=ssl.create_default_context())
        s.login(env["SMTP_USER"], env["SMTP_PASS"])
        refused = s.send_message(msg)
    result = f"SENT {msg['Message-ID']}" + (f" refused={list(refused)}" if refused else "")
except Exception as e:
    result = f"SEND FAILED {type(e).__name__}: {str(e)[:120]}"
with open(LOG, "a") as f:
    f.write(f"{now:%Y-%m-%dT%H:%M:%SZ} RUN {'OK' if ok else 'WARN'} issues={len(issues)} {result}\n")
print(result)
if result.startswith("SEND FAILED"):
    print(f"chess-health-report: {result}", file=sys.stderr); sys.exit(1)
PY
