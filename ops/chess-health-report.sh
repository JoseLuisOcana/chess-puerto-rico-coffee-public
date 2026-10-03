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
#   - TLS certificate of every hostname on the server (connect by IP with SNI, full chain + hostname check): warn under 21 days.
#     Also reads Plesk's copy (the file Apache's SSLCertificateFile points at): warn when Plesk has NOT renewed it by
#     29.5 days left (Plesk renews 30 days ahead, at :39 past the hour), and when nginx still serves an older serial
#     than Plesk's more than 3.5 days after Plesk renewed (the drift checker runs every 3 days, 13:00 AST, days 1,4,7…;
#     inside that grace it is listed, not flagged). Lists every certificate Plesk renewed in the last 7 days.
#   - last REAL run of each cron (dry-runs are ignored): result, and age against its schedule
#       puzzle recycle 04:15 daily (26 h), mongodump 03:30 daily (26 h), auto-feed Mon+Thu 08:00 (4.5 days),
#       video refresh Sun 07:00 (8 days), bgjobs cleanup Sun 04:45 (8 days)
#   - lila-docker containers: any not running, unhealthy, or with RestartCount > 0 — except EXPECTED_STOPPED below:
#     elasticvue (Elasticsearch web UI) and mailpit (dev mail catcher; real mail goes through IONOS) are dev tools in the
#     active `search`/`email` profiles that have been stopped on purpose since 2026-09-13; they are listed, not flagged.
#   - last 7 days of lila error.log (ERROR lines) and nginx error.log (emerg/alert/crit). Two KNOWN-BENIGN nginx patterns
#     are counted separately and do not warn: "open() …/logs/proxy_* failed (13: Permission denied)" = nightly logrotate:
#     nginx workers can't reopen Plesk per-site logs (harmless). /etc/logrotate.d/nginx sends nginx USR1 at ~00:00:10;
#     the root master reopens every log, then each of the 12 www-data workers fails on the 21 per-site logs because
#     Plesk keeps each /var/www/vhosts/system/<site>/logs dir psaadm:root 700 (12 x 21 = 252 lines/day). The workers
#     keep their open handles and Plesk only empties those files in place, so no log lines are lost),
#     client-side TLS aborts ("SSL_do_handshake()",
#     "SSL_read()" or "SSL_write() failed"), and emerg lines about a config file outside /etc/nginx (someone running
#     `nginx -t` on a scratch copy). Anything else at emerg/alert/crit warns.
#   - RAM and swap: warn when available RAM < 10 % or swap > 50 % used
#   (added 2026-10-03, second batch — owner request)
#   - nginx: warn when nothing listens on :443 or :80 (the 2026-09-17 "inherited sockets" trap: nginx active and
#     `nginx -t` clean, yet a port silently missing), when `nginx -T` fails, and when any file nginx LOADS (per
#     `nginx -T`, symlinks followed, per-site vhost_nginx.conf included) is not byte-identical to a file in the
#     PUSHED state (origin/main) of the private server-config-backup repo. Package module stubs
#     (/usr/share/nginx/modules-available) are exempt — reinstallable.
#   - packages: warn on security updates not installed (apt-get -s dist-upgrade, no lock, no `apt update` — the
#     lists come from apt-daily; warn if those are > 2 days old), on unattended-upgrades "has conffile prompt" lines
#     (= an update SKIPPED because we edited one of its config files, e.g. nginx.conf) or ERROR lines in the last
#     7 days, when sw-nginx (Plesk's nginx) leaves dpkg state "rc" (installed = the 2026-09-17 disaster; gone from
#     dpkg = it was PURGED, which can delete live /etc/nginx files), when the apt pin
#     /etc/apt/preferences.d/no-sw-nginx is missing or sw-nginx has an install candidate, and when /usr/sbin/nginx
#     is not Ubuntu's nginx-core. From 2027-01-01, on Ubuntu 22.04 without Ubuntu Pro attached: "Ubuntu 22.04
#     support ends April 2027: plan Ubuntu Pro or 24.04".
#   - Let's Encrypt: ERR/WARN lines from Plesk's letsencrypt/sslit extensions in /var/log/plesk/panel.log (Plesk logs
#     nothing on a successful renewal), and FAIL lines of the cert drift checker (/var/log/le-cert-renewal-check.log),
#     last 7 days.
#
# Usage: chess-health-report.sh [--dry-run] [--test] [--label TEXT]
#   --dry-run     print the report, send nothing
#   --test        send, with "[test]" at the end of the subject
#   --label TEXT  an extra (non-weekly) run: subject says "health report (TEXT)" instead of "weekly health report"
# (Public copy: the other sites hosted on this server, their checks and the backup repo path are not listed;
# otherwise identical to the deployed script.)

set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "chess-health-report: run as root" >&2; exit 1; fi
exec 9>/run/lock/chess-health-report.lock
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP another run holds the lock" >> /var/log/chess-health-report.log; exit 0; }

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, gzip, hashlib, json, os, re, shutil, smtplib, socket, ssl, subprocess, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

LOG = "/var/log/chess-health-report.log"
PROJECT = "/opt/chess/lila-docker"
ENV_FILE = "/etc/chess-contact.env"
TO = "system@chesspuertoricocoffee.com"
PROBE_IP = "82.165.212.204"   # connect by IP + SNI (one hostname resolves to a loopback address locally)
HOSTS = ["chesspuertoricocoffee.com", "www.chesspuertoricocoffee.com"]  # public copy: the other sites on this server are not listed
CERT_WARN_DAYS = 21
PLESK_RENEW_WARN_DAYS = 29.5   # Plesk renews 30 days ahead, normally within the hour (its task runs at :39)
DRIFT_GRACE_DAYS = 3.5         # check-le-cert-renewal-all.sh: cron "0 13 */3 * *" = 13:00 AST on days 1,4,7,…,31
BACKUP_REPO = "/home/ADMIN/projects/server-config-backup"   # public copy: path of the private config-backup repo
SW_NGINX_PIN = "/etc/apt/preferences.d/no-sw-nginx"
EXPECTED_STOPPED = {"elasticvue": "Elasticsearch web UI, dev tool", "mailpit": "dev mail catcher; real mail goes via IONOS"}
AST = dt.timezone(dt.timedelta(hours=-4))   # America/Puerto_Rico, no DST
UTC = dt.timezone.utc

ap = argparse.ArgumentParser(prog="chess-health-report.sh")
ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--test", action="store_true")
ap.add_argument("--label", default="")
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
def plesk_cert(host):
    """Serial, notBefore, notAfter of the certificate Plesk/Apache uses for host (read-only)."""
    d = host if os.path.isdir(f"/var/www/vhosts/system/{host}") else host.removeprefix("www.")
    m = re.search(r'^\s*SSLCertificateFile\s+"?([^"\s]+)', open(f"/var/www/vhosts/system/{d}/conf/httpd.conf").read(), re.M)
    o = subprocess.run(["openssl", "x509", "-noout", "-serial", "-startdate", "-enddate", "-in", m.group(1)],
                       capture_output=True, text=True, check=True).stdout
    f = dict(l.split("=", 1) for l in o.splitlines() if "=" in l)
    p = lambda s: dt.datetime.strptime(s.strip(), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
    return f["serial"].strip().upper().lstrip("0"), p(f["notBefore"]), p(f["notAfter"])


def next_drift_check():
    t = now.astimezone(AST).replace(hour=13, minute=0, second=0, microsecond=0)
    return next(c for c in (t + dt.timedelta(days=i) for i in range(40)) if (c.day - 1) % 3 == 0 and c > now)


out = [f"TLS CERTIFICATES (served: warn under {CERT_WARN_DAYS} days; Plesk's copy: warn if not renewed by "
       f"{PLESK_RENEW_WARN_DAYS:g} days left)"]
ctx = ssl.create_default_context()
renewed = []
for h in HOSTS:
    try:
        with socket.create_connection((PROBE_IP, 443), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=h) as tls:
                pc = tls.getpeercert()
        end = dt.datetime.fromtimestamp(ssl.cert_time_to_seconds(pc["notAfter"]), UTC)
        days = (end - now).days
        flag = warn(f"{h} certificate expires in {days} days") if days < CERT_WARN_DAYS else ""
        line = f"{h:44} {days:3d} days (until {end:%b %d %Y})"
    except Exception as e:
        out.append(warn(f"{h} TLS check failed") + f"{h:44} FAILED: {type(e).__name__}: {str(e)[:80]}")
        continue
    try:
        serial, nb, na = plesk_cert(h)
        left = (na - now).total_seconds() / 86400
        if now - nb < dt.timedelta(days=7):
            renewed.append(f"{h} on {nb.astimezone(AST):%a %b %d %H:%M} AST (until {na:%b %d %Y})")
        if left < PLESK_RENEW_WARN_DAYS:
            flag = warn(f"{h}: Plesk has NOT renewed its certificate ({left:.1f} days left; Plesk renews at 30)")
        if serial == pc.get("serialNumber", "").upper().lstrip("0"):
            line += "  same as Plesk's"
        elif now - nb > dt.timedelta(days=DRIFT_GRACE_DAYS):
            flag = warn(f"{h}: nginx still serves an OLD certificate; Plesk's renewed one (until {na:%b %d %Y}) "
                        f"is unused — the drift checker did not switch it")
            line += f"  DRIFT: Plesk's renewed one runs until {na:%b %d %Y}"
        else:
            line += (f"  Plesk renewed it (until {na:%b %d %Y}); nginx switches at the drift check "
                     f"{next_drift_check():%a %b %d %H:%M} AST")
    except Exception as e:
        flag = warn(f"{h}: could not read Plesk's certificate")
        line += f"  (Plesk's copy unreadable: {type(e).__name__})"
    out.append(flag + line)
out.append("Renewed by Plesk in the last 7 days: " + ("; ".join(renewed) if renewed else "none"))
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
out.append(f"    known benign (not counted): {benign_perm} lines from the nightly logrotate: nginx workers can't reopen Plesk per-site "
           f"logs (harmless); {benign_tls} client TLS aborts; "
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

# ---------------------------------------------------------------- 8. nginx: listeners + loaded files vs backup repo
out = ["NGINX (listeners; every loaded config file vs server-config-backup, pushed state)"]
ports = {}
for l in subprocess.run(["ss", "-ltnpH"], capture_output=True, text=True).stdout.splitlines():
    f = l.split()
    if len(f) >= 4 and '"nginx"' in l:
        ports.setdefault(f[3].rsplit(":", 1)[1], set()).add(f[3])
for p in ("443", "80"):
    if p in ports:
        out.append(f"nginx listening on :{p} ({', '.join(sorted(ports[p]))})")
    else:
        out.append(warn(f"nginx is NOT listening on :{p}") + f"nginx NOT listening on :{p} — if nginx is active and "
                   f"`nginx -t` passes, it is the inherited-sockets trap: systemctl stop nginx, then start")
t = subprocess.run(["nginx", "-T"], capture_output=True, text=True)
if t.returncode != 0:
    out.append(warn("nginx -T fails: the nginx configuration is INVALID") + "nginx -T: " +
               (t.stderr.strip().splitlines() or ["?"])[-1][:120])
else:
    try:
        git = ["git", "-c", f"safe.directory={BACKUP_REPO}", "-C", BACKUP_REPO]
        ref = "origin/main" if subprocess.run(git + ["rev-parse", "-q", "--verify", "origin/main"],
                                              capture_output=True).returncode == 0 else "HEAD"
        head = subprocess.run(git + ["rev-parse", "--short", ref], capture_output=True, text=True, check=True).stdout.strip()
        blobs = {l.split()[2] for l in subprocess.run(git + ["ls-tree", "-r", ref], capture_output=True, text=True,
                                                      check=True).stdout.splitlines()}
        loaded = list(dict.fromkeys(re.findall(r"^# configuration file (.+):$", t.stdout, re.M)))
        missing, exempt = [], 0
        for p in loaded:
            real = os.path.realpath(p)
            if real.startswith("/usr/share/nginx/modules-available/"):
                exempt += 1; continue
            data = open(real, "rb").read()
            if hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest() not in blobs:
                missing.append(p)
        if missing:
            out.append(warn(f"{len(missing)} loaded nginx file(s) not in server-config-backup (or changed since the "
                            f"last push)") + f"{len(missing)} of {len(loaded) - exempt} loaded files NOT in the backup "
                       f"repo ({ref} {head}):")
            out += [f"    {p}" for p in missing[:10]]
        else:
            out.append(f"all {len(loaded) - exempt} loaded config files are byte-identical in server-config-backup "
                       f"({ref} {head}); {exempt} package module stubs exempt")
    except Exception as e:
        out.append(warn("could not compare nginx files with server-config-backup") +
                   f"backup comparison failed: {type(e).__name__}: {str(e)[:100]}")
sections.append(out)

# ---------------------------------------------------------------- 9. packages and updates
out = ["PACKAGES AND UPDATES"]
cenv = {**os.environ, "LC_ALL": "C"}
try:
    stamp = os.path.getmtime("/var/lib/apt/periodic/update-success-stamp")
    lists_age = (now.timestamp() - stamp) / 86400
except OSError:
    lists_age = 99
sim = subprocess.run(["apt-get", "-s", "-o", "Debug::NoLocking=1", "dist-upgrade"], capture_output=True, text=True, env=cenv)
inst = [l for l in sim.stdout.splitlines() if l.startswith("Inst ")]
sec = sorted({l.split()[1] for l in inst if "-security" in l})
flag = warn(f"{len(sec)} security update(s) not installed: {', '.join(sec[:6])}") if sec else ""
out.append(f"{flag}{len(sec)} security updates pending, {len(inst) - len(sec)} other updates pending"
           + (f" ({', '.join(sorted({l.split()[1] for l in inst if '-security' not in l})[:6])})" if len(inst) > len(sec) else ""))
flag = warn(f"apt package lists are {lists_age:.1f} days old (apt-daily not refreshing)") if lists_age > 2 else ""
out.append(f"{flag}package lists refreshed {lists_age * 24:.0f} h ago" if lists_age < 99 else f"{flag}package lists: never refreshed")
uu_prompt, uu_err, uu_kept, uu_last = set(), [], set(), None
for l in read_all("/var/log/unattended-upgrades/unattended-upgrades.log*"):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\d+ (\w+) (.*)", l)
    if not m: continue
    tl = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST)
    if tl < since: continue
    if "Starting unattended upgrades script" in m.group(3): uu_last = max(uu_last or tl, tl)
    pm = re.match(r"Package (\S+) has conffile prompt", m.group(3))
    if pm: uu_prompt.add(pm.group(1))
    if m.group(2) == "ERROR": uu_err.append(m.group(3)[:100])
    km = re.match(r"Packages that are kept back: (.+)", m.group(3))
    if km and km.group(1).strip(): uu_kept.update(km.group(1).split())
flag = warn(f"update(s) SKIPPED because a config file was edited: {', '.join(sorted(uu_prompt))} — upgrade by hand") \
    if uu_prompt else ""
out.append(f"{flag}unattended-upgrades, last 7 days: {len(uu_prompt)} skipped for an edited config file"
           f"{' (' + ', '.join(sorted(uu_prompt)) + ')' if uu_prompt else ''}, {len(uu_err)} ERROR lines, "
           f"kept back: {', '.join(sorted(uu_kept)) or 'none'}; last run "
           + (f"{uu_last:%a %b %d %H:%M} AST" if uu_last else "NOT in the last 7 days"))
if uu_err:
    warn(f"unattended-upgrades logged {len(uu_err)} ERROR line(s)"); out.append(f"    {uu_err[-1]}")
if not uu_last:
    warn("unattended-upgrades has not run in 7 days")
q = subprocess.run(["dpkg-query", "-W", "-f=${db:Status-Abbrev}|${Version}", "sw-nginx"], capture_output=True, text=True)
state = q.stdout.split("|")[0].strip() if q.returncode == 0 else "unknown"
if state == "rc":
    out.append("sw-nginx (Plesk's nginx): rc = removed, config registered, NOT installed — as it must be")
elif state == "unknown":
    out.append(warn("sw-nginx was PURGED (dpkg no longer knows it) — check /etc/nginx files still exist") +
               "sw-nginx: GONE from dpkg = purged. Check /etc/nginx/nginx.conf, mime.types, fastcgi*, conf.d/fixssl.conf")
else:
    out.append(warn(f"sw-nginx (Plesk's nginx) is in dpkg state '{state}' — expected 'rc' (see CLAUDE.md)") +
               f"sw-nginx: state '{state}' ({q.stdout.split('|')[-1]}) — Plesk's nginx may be INSTALLED")
pol = subprocess.run(["apt-cache", "policy", "sw-nginx"], capture_output=True, text=True, env=cenv).stdout
pin_ok = os.path.exists(SW_NGINX_PIN) and re.search(r"^Pin-Priority:\s*-1\s*$", open(SW_NGINX_PIN).read(), re.M)
cand = (re.search(r"Candidate:\s*(\S+)", pol) or [None, "?"])[1]
if pin_ok and cand == "(none)":
    out.append(f"apt pin {SW_NGINX_PIN}: present, sw-nginx has no install candidate")
else:
    probs = ([] if pin_ok else [f"apt pin {SW_NGINX_PIN} is MISSING"]) + \
            ([] if cand == "(none)" else [f"sw-nginx CAN be installed (candidate {cand})"])
    out.append(warn("; ".join(probs)) + f"apt pin: {'present' if pin_ok else 'MISSING'}, sw-nginx candidate {cand}")
own = subprocess.run(["dpkg", "-S", "/usr/sbin/nginx"], capture_output=True, text=True).stdout.split(":")[0]
if own != "nginx-core":
    out.append(warn(f"/usr/sbin/nginx belongs to '{own or 'no package'}', not Ubuntu's nginx-core") +
               f"/usr/sbin/nginx owner: {own or 'none'}")
osr = dict(l.strip().split("=", 1) for l in open("/etc/os-release") if "=" in l)
ver = osr.get("VERSION_ID", "").strip('"')
try:
    pro = bool(json.load(open("/var/lib/ubuntu-advantage/status.json")).get("attached"))
except Exception:
    pro = False
if ver == "22.04":
    if now >= dt.datetime(2027, 1, 1, tzinfo=AST) and not pro:
        out.append(warn("Ubuntu 22.04 support ends April 2027: plan Ubuntu Pro or 24.04") +
                   "Ubuntu 22.04 support ends April 2027: plan Ubuntu Pro or 24.04")
    else:
        out.append(f"Ubuntu 22.04, Ubuntu Pro {'attached' if pro else 'not attached'}"
                   + ("" if pro else " (support ends April 2027; this becomes a warning from Jan 2027)"))
else:
    out.append(f"Ubuntu {ver}")
sections.append(out)

# ---------------------------------------------------------------- 10. Let's Encrypt: Plesk errors, drift checker
out = ["LET'S ENCRYPT (Plesk renewal errors; nginx cert drift checker), last 7 days"]
le_err = []
for l in read_all("/var/log/plesk/panel.log*"):
    m = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+\] \S+ (ERR|WARN|CRIT)\s+\[extension/(?:letsencrypt|sslit)\] (.*)", l)
    if m and dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST) >= since:
        le_err.append(f"{m.group(1)[5:16]} {m.group(2)} {m.group(3)[:100]}")
flag = warn(f"{len(le_err)} Let's Encrypt error/warning line(s) in Plesk's panel.log") if le_err else ""
out.append(f"{flag}Plesk panel.log: {len(le_err)} Let's Encrypt ERR/WARN lines")
out += [f"    {e}" for e in le_err[-3:]]
dl = [l for l in tail_lines("/var/log/le-cert-renewal-check.log") if re.match(r"\d{4}-\d\d-\d\dT\S+Z ", l)
      and iso(l.split()[0]) >= since]
fails = [l for l in dl if " FAIL" in l]
flag = warn(f"cert drift checker: {len(fails)} FAIL line(s)") if fails else ""
last = iso(dl[-1].split()[0]) if dl else None
out.append(f"{flag}drift checker: {len(fails)} FAIL, {sum(' no-op' in l for l in dl)} no-op, "
           f"{len(dl) - len(fails) - sum(' no-op' in l for l in dl)} other lines; last run "
           + (f"{last.astimezone(AST):%a %b %d %H:%M} AST" if last else "none in 7 days")
           + f"; next {next_drift_check():%a %b %d %H:%M} AST")
out += [f"    {l[:120]}" for l in fails[-2:]]
sections.append(out)

# ---------------------------------------------------------------- 11-12. (public copy: the checks of another site on this server are omitted)

# ---------------------------------------------------------------- compose + send
ok = not issues
kind = f"health report ({args.label})" if args.label else "weekly health report"
subject = (f"{'✅' if ok else '⚠️'} Chess Puerto Rico Coffee — {kind}, {now.astimezone(AST):%a %b %d, %Y}"
           + ("" if ok else f" — {len(issues)} item(s) need attention") + (" [test]" if args.test else ""))
body = [f"{kind[0].upper() + kind[1:]} for chesspuertoricocoffee.com — {now.astimezone(AST):%Y-%m-%d %H:%M} AST",
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
if sys.stdout.isatty():   # cron: stay silent on success (cron mails any output to MAILTO)
    print(result)
if result.startswith("SEND FAILED"):
    print(f"chess-health-report: {result}", file=sys.stderr); sys.exit(1)
PY
