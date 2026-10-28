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
#   - versions of the chess stack (lila commit + local commits, lila-fishnet, lila-ws image, fishnet, mongo/redis), informational
#   - UPSTREAM (added 2026-10-28, owner request): read-only — GitHub's public REST API only (unauthenticated, 60 calls an
#     hour per IP; a run makes 7) plus local read-only git; nothing is fetched or pulled. (1) Security advisories of
#     lichess-org/lila, lila-ws and lila-fishnet published after what runs here (lila: the upstream commit the local
#     branch is based on = merge-base of HEAD with origin/master or master, whichever is newer; lila-fishnet: its HEAD;
#     lila-ws: the build time of the running image): each one is an "UPGRADE NOW" attention item, unless a commit named
#     in its patched_versions is already in the build (lila, lila-fishnet: `git merge-base --is-ancestor` locally;
#     lila-ws: the commit its image was built from, found in the image-publish workflow runs, compared on GitHub) — then
#     it is listed with ℹ️. A failed advisory lookup warns too (a silent miss would look like "no advisories").
#     (2) Age of the lila base commit and how many commits upstream master is ahead: "UPGRADE SUGGESTED" when the base
#     is older than 60 days. (3) Newer fishnet release / newer lila-ws image (publish runs after the running image's
#     build time): informational.
#   - BLOG APPROVAL (added 2026-10-08): lists published blog posts nobody has rated yet. They stay out of the community
#     list and blog search until a moderator clicks Weak or Good on the post page (Spam = reject). Each
#     waiting post is an attention item, with its link.
#   - SEARCH (added 2026-10-08 with the search-index rebuild): runs the read-only check of
#     /usr/local/sbin/chess-search-rebuild.sh — Elasticsearch green, the auto-create guard set, all five indexes present
#     with lila-search's real mappings and document counts equal to MongoDB, search containers running; warns per FAIL.
#   - PREBUILT apps (added 2026-10-08, lila + lila-fishnet run from `sbt stage` builds in lila-docker/prebuilt/<app>/,
#     not `sbt run`): warns when a container is NOT running its prebuilt start script (= sbt rollback mode, ~5 GB more
#     RAM), when the code in repos/<repo> has commits or uncommitted edits that the current build does not contain (a
#     code change does nothing until `sudo chess-rebuild-lila.sh`), and when the running process uses another build
#     than prebuilt/<app>/current (rebuilt with --no-restart, not restarted yet).
#   - lila-docker containers: any not running, unhealthy, or with RestartCount > 0 — except EXPECTED_STOPPED below:
#     elasticvue (Elasticsearch web UI) and mailpit (dev mail catcher; real mail goes through IONOS) are dev tools in the
#     active `search`/`email` profiles that have been stopped on purpose since 2026-09-13; they are listed, not flagged.
#     Restarts that line up with a Docker/containerd package update (added 2026-10-20) are listed as "ℹ️ restarted by
#     Docker update (normal)", not flagged: upgrading docker-ce or containerd.io restarts dockerd and every container,
#     and one that loses the start-up race (MongoDB or Elasticsearch not ready yet) is restarted by its `unless-stopped`
#     policy. Restarts with no matching update in /var/log/apt/history.log* or /var/log/dpkg.log* still warn (section 5).
#   - last 7 days of lila error.log (ERROR lines) and nginx error.log (emerg/alert/crit). lila's SHUTDOWN errors logged
#     while a Docker/containerd update was running (e.g. "'interrupted at shutdown' (code = 11600)", "lila-ws stop …
#     Lilakka.shutdown timeout") are listed with ℹ️, not counted (added 2026-10-20). Two KNOWN-BENIGN nginx patterns
#     are counted separately and do not warn: "open() …/logs/proxy_* failed (13: Permission denied)" = nightly logrotate:
#     nginx workers can't reopen Plesk per-site logs (harmless). /etc/logrotate.d/nginx sends nginx USR1 at ~00:00:10;
#     the root master reopens every log, then each of the 12 www-data workers fails on the 21 per-site logs because
#     Plesk keeps each /var/www/vhosts/system/<site>/logs dir psaadm:root 700 (12 x 21 = 252 lines/day). The workers
#     keep their open handles and Plesk only empties those files in place, so no log lines are lost),
#     client-side TLS aborts ("SSL_do_handshake()",
#     "SSL_read()" or "SSL_write() failed"), and emerg lines about a config file outside /etc/nginx (someone running
#     `nginx -t` on a scratch copy) or failing to open a file under /tmp/claude-* (a Claude Code test rig, 2026-10-08). Anything else at emerg/alert/crit warns.
#     RULE A (added 2026-10-28): an emerg/alert/crit line logged within 10 minutes (either side) of a dpkg.log
#     "install" or "upgrade" of a package that restarts nginx is listed with ℹ️, not counted; its reason lists EVERY such
#     package event inside that window, in time order (2026-10-28: was only the nearest one). Those
#     packages: nginx, nginx-core/-common/-full/-light/-extras, libnginx-mod-*, sw-nginx, any name containing
#     "passenger" (Plesk's passenger postinst runs `pleskrc nginx try-restart`), and the Plesk components whose
#     maintainer scripts restart nginx (plesk-core, plesk-modsecurity-crs; found by scanning /var/lib/dpkg/info
#     2026-10-28). A restart makes the old worker log "open socket #N left in connection" + "aborting" (2026-10-26
#     passenger, 2026-10-27 nginx-core). Every other emerg/alert/crit line still warns.
#     RULE D (added 2026-10-28): REBOOTS, handled like Docker updates. A reboot is read from wtmp (`last -x`: the
#     "shutdown system down" time + the "reboot system boot" time) and the journal boot list (previous boot's last entry
#     + this boot's first entry, used when wtmp has no record for that boot). A container restart (last start), or an
#     ERROR entry in lila's error.log (lila and its lila-ws socket and MongoDB "connection closed" lines all land there),
#     is listed with ℹ️ and the reboot time, not counted, ONLY when it falls between 2 min before the recorded shutdown
#     and 10 min after the boot AND the same service shows no further restart / ERROR in the 30 min after that window
#     (the report must run at least 30 min after the window, or it still warns). Nothing else is affected: an nginx or
#     unattended-upgrades line in the window, a restart 20 min after boot, an OOM kill or an unhealthy container warn.
#     Seen 2026-10-28: the search ingestor restarted twice because Elasticsearch opened :9200 21 s after it started, and
#     lila logged 3 shutdown errors while the host went down; compose depends_on would not help (dockerd starts the
#     containers at boot, not compose).
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
#     RULE B (added 2026-10-28): an unattended-upgrades ERROR "Lock could not be acquired" (case-insensitive; another
#     package manager, e.g. Plesk's installer at ~06:26 AST, held the apt lock) is listed with ℹ️, not counted, only
#     when a later unattended-upgrades run starting within 24 h finished cleanly (no ERROR/CRITICAL line and a
#     completion line: "No packages found that can be upgraded unattended", "All upgrades installed" or "Packages that
#     were upgraded"). Every other ERROR line, and a lock error with no such run, still warns.
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
# Test hooks (with --dry-run only): CHESS_HR_TEST_APT_GLOB, CHESS_HR_TEST_DPKG_GLOB, CHESS_HR_TEST_LILA_ERRLOG_GLOB and
# CHESS_HR_TEST_COMPOSE_PROJECT replace /var/log/apt/history.log*, /var/log/dpkg.log*, lila's error.log* and the
# compose project whose containers are checked.
# Added 2026-10-28: CHESS_HR_TEST_NGINX_ERRLOG_GLOB and CHESS_HR_TEST_UU_GLOB replace /var/log/nginx/error.log* and
# /var/log/unattended-upgrades/unattended-upgrades.log*; CHESS_HR_TEST_NOW and CHESS_HR_TEST_SINCE (ISO 8601, e.g.
# 2026-10-28T17:00:00Z) set the report time and the start of the error/updates window (default: 7 days back);
# CHESS_HR_TEST_LOG receives the DRY line instead of /var/log/chess-health-report.log.
# Added 2026-10-28 (RULE D): CHESS_HR_TEST_BOOTS = a file with one reboot per line, "SHUTDOWN BOOT" in ISO 8601 ("-" for
# no recorded shutdown), replacing wtmp + the journal boot list; CHESS_HR_TEST_CONTAINERS_JSON = a `docker inspect` JSON
# array replacing the live containers of the compose project.
# Added 2026-10-28 (UPSTREAM): CHESS_HR_TEST_GITHUB_DIR = a directory of JSON files replacing api.github.com: the API
# path with every "/", "?", "&" and "=" turned into "_", plus ".json" (a missing file = that call fails).

set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "chess-health-report: run as root" >&2; exit 1; fi
exec 9>/run/lock/chess-health-report.lock
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP another run holds the lock" >> /var/log/chess-health-report.log; exit 0; }

exec python3 - "$@" <<'PY'
import argparse, datetime as dt, glob, gzip, hashlib, json, os, re, shutil, smtplib, socket, ssl, subprocess, sys
import urllib.error, urllib.request
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
TEST_ENV = sorted(k for k in os.environ if k.startswith("CHESS_HR_TEST_"))
if TEST_ENV and not args.dry_run:
    sys.exit(f"chess-health-report: {', '.join(TEST_ENV)} set: test hooks only work with --dry-run")
now = (dt.datetime.fromisoformat(os.environ["CHESS_HR_TEST_NOW"].replace("Z", "+00:00"))
       if "CHESS_HR_TEST_NOW" in os.environ else dt.datetime.now(UTC))
LOG = os.environ.get("CHESS_HR_TEST_LOG", LOG)
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

# prebuilt apps (2026-10-08): which start command does each container run?
# The app runs from {PROJECT}/prebuilt/<app>/current -> builds/<time>-<commit> (chess-rebuild-lila.sh).
PREBUILT = {"lila": ("prebuilt/lila", "bin/lila"), "lila_fishnet": ("prebuilt/lila-fishnet", "bin/lila-fishnet")}
def container_info(svc):   # (entrypoint list, builds/<x> folder the java process runs from or "")
    r = subprocess.run(["docker", "inspect", "-f", "{{json .Config.Entrypoint}}|{{.State.Pid}}", f"lila-docker-{svc}-1"],
                       capture_output=True, text=True)
    try:
        ep, pid = r.stdout.strip().split("|", 1)
        ep = json.loads(ep) or []
    except ValueError:
        return [], ""
    try:
        m = re.search(r"builds/[^/\x00]+", open(f"/proc/{int(pid)}/cmdline", "rb").read().decode(errors="replace"))
    except (OSError, ValueError):
        m = None
    return ep, (m.group(0) if m else "")
def runs_prebuilt(svc):
    ep, _ = container_info(svc)
    return any(str(x) == "/opt/prebuilt/current/" + PREBUILT[svc][1] for x in ep)


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
    # since 2026-10-08 lila runs prebuilt (no sbt, no bg-jobs): the script's fail-safe SKIP is then the normal result
    ok = st.startswith("done:") or (st.startswith("SKIP: no running process uses bg-jobs") and runs_prebuilt("lila"))
    out.append(cron_row("bgjobs cleanup", t, ("not needed, lila runs prebuilt — " if ok and st.startswith("SKIP") else "") + st[:90], ok, 8 * 24))
else:
    out.append(cron_row("bgjobs cleanup", None, "", False, 8 * 24))
sections.append(out)

# ---------------------------------------------------------------- 5. containers
def read_all(pattern):
    for p in sorted(glob.glob(pattern)):
        try:
            op = gzip.open if p.endswith(".gz") else open
            with op(p, "rt", errors="replace") as f:
                yield from f
        except OSError:
            continue


# Docker/containerd package updates (added 2026-10-20). Upgrading docker-ce or containerd.io restarts dockerd, which
# stops and restarts every container (live-restore is off). Plesk's daily system update (`pum --update`, ~06:26 AST,
# /var/log/plesk/systemupdatestool.log) installs them 2-4 times a month. On 2026-10-15 lila (MongoDB not ready within
# its 5-s startup timeout) and the search ingestor (Elasticsearch not listening yet) lost that start-up race and were
# restarted by `unless-stopped` within 25 s. dockerd resets RestartCount when it starts a container again (so does a
# manual start/restart), so a count > 0 only counts restarts since then: when the LAST restart (State.StartedAt) lies
# in an update's window, every counted restart does. A run = Start-Date..End-Date of an apt history entry that
# upgraded/installed a DOCKER_PKGS package, or the time of such an "upgrade|install" line in dpkg.log. docker-ce-cli
# and the plugins do not restart the daemon and do not count. Times in both logs are local (AST); Docker's are UTC.
# An OOM kill is never "normal": Docker clears State.OOMKilled when it restarts the container (tested 2026-10-20), so
# the kernel log is read instead (an "oom-kill:" line names the container's cgroup docker-<full id>.scope).
DOCKER_PKGS = {"docker-ce", "containerd.io", "docker.io", "containerd"}
RESTART_BEFORE, RESTART_AFTER = dt.timedelta(minutes=2), dt.timedelta(minutes=10)   # restart window around a run
STOP_BEFORE, STOP_AFTER = dt.timedelta(minutes=1), dt.timedelta(minutes=1)          # lila shutdown ERRORs (section 6)
APT_HISTORY = os.environ.get("CHESS_HR_TEST_APT_GLOB", "/var/log/apt/history.log*")
DPKG_LOG = os.environ.get("CHESS_HR_TEST_DPKG_GLOB", "/var/log/dpkg.log*")
COMPOSE_PROJECT = os.environ.get("CHESS_HR_TEST_COMPOSE_PROJECT", "lila-docker")
KERN_LOG = "/var/log/kern.log*"


def local_time(s):
    return dt.datetime.strptime(" ".join(s.split()), "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST)


def short_ver(v):   # "5:29.9.0-1~ubuntu.22.04~jammy" -> "29.9.0"
    return re.sub(r"-[^-]*$", "", re.sub(r"^\d+:", "", v.strip()))


docker_runs = []   # (start, end, what): apt history entries first, so they win over the same run's dpkg lines
run_start = run_pkgs = None
for l in read_all(APT_HISTORY):
    if l.startswith("Start-Date:"):
        run_start, run_pkgs = local_time(l.split(":", 1)[1]), []
    elif run_start and re.match(r"(Install|Upgrade|Reinstall|Downgrade): ", l):
        for pkg, vers in re.findall(r"([\w.+-]+):[\w-]+ \(([^)]*)\)", l):
            if pkg in DOCKER_PKGS:
                run_pkgs.append(f"{pkg} " + " → ".join(short_ver(v) for v in vers.split(",") if v.strip() != "automatic"))
    elif l.startswith("End-Date:") and run_start:
        if run_pkgs:
            docker_runs.append((run_start, local_time(l.split(":", 1)[1]), ", ".join(run_pkgs)))
        run_start = None
for l in read_all(DPKG_LOG):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (upgrade|install) ([\w.+-]+):\S+ (\S+) (\S+)", l)
    if m and m.group(3) in DOCKER_PKGS:
        t = local_time(m.group(1))
        docker_runs.append((t, t, f"{m.group(3)} {short_ver(m.group(4))} → {short_ver(m.group(5))}"))


def docker_run_at(t, before, after):
    return next((r for r in docker_runs if r[0] - before <= t <= r[1] + after), None)


def run_txt(r):
    return f"{r[0].astimezone(AST):%a %b %d %H:%M} AST: {r[2]}"


# RULE D (2026-10-28, see the header): reboots, the same way as Docker updates above.
REBOOT_BEFORE, REBOOT_AFTER, REBOOT_QUIET = dt.timedelta(minutes=2), dt.timedelta(minutes=10), dt.timedelta(minutes=30)


def iso_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


reboots = []   # (recorded shutdown, boot, source); shutdown = boot when none was recorded (crash, power loss)
if "CHESS_HR_TEST_BOOTS" in os.environ:
    for l in open(os.environ["CHESS_HR_TEST_BOOTS"]):
        f_ = l.split()
        if len(f_) >= 2 and not f_[0].startswith("#"):
            reboots.append((iso_time(f_[1]) if f_[0] == "-" else iso_time(f_[0]), iso_time(f_[1]), "test"))
else:
    w_ = subprocess.run(["last", "-x", "--time-format", "iso", "reboot", "shutdown"], capture_output=True, text=True).stdout
    downs = [iso_time(m.group(1)) for m in re.finditer(r"^shutdown\s+system down\s+\S+\s+(\S+)", w_, re.M)]
    for m in re.finditer(r"^reboot\s+system boot\s+\S+\s+(\S+)", w_, re.M):
        b_ = iso_time(m.group(1))
        reboots.append((max((x for x in downs if b_ - dt.timedelta(days=1) <= x <= b_), default=b_), b_, "wtmp"))
    j_ = subprocess.run(["journalctl", "--list-boots", "--no-pager"], capture_output=True, text=True).stdout
    spans = [(local_time(m.group(1)), local_time(m.group(2)))
             for m in re.finditer(r"\w{3} (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \w+—\w{3} (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", j_)]
    for (_, prev_end), (b_, _) in zip(spans, spans[1:]):
        if not any(abs(r[1] - b_) <= REBOOT_BEFORE for r in reboots):
            reboots.append((prev_end, b_, "journal"))


def reboot_at(t):   # the reboot whose window [shutdown - 2 min, boot + 10 min] holds t, or None
    return next((r for r in reboots if r[0] - REBOOT_BEFORE <= t <= r[1] + REBOOT_AFTER), None)


def reboot_quiet_seen(r):   # the 30 min after the window have passed (so "nothing further" is a fact, not a guess)
    return now >= r[1] + REBOOT_AFTER + REBOOT_QUIET


def reboot_txt(r):
    return f"shutdown {r[0].astimezone(AST):%a %b %d %H:%M:%S}, boot {r[1].astimezone(AST):%H:%M:%S} AST ({r[2]})"


oom_kills = {}   # container id -> kernel OOM-kill times (syslog time is local and has no year)
for l in read_all(KERN_LOG):
    m = re.search(r"oom-kill:.*?docker-([0-9a-f]{64})\.scope", l)
    if m:
        try:
            t = dt.datetime.strptime(f"{now.year} {' '.join(l.split()[:3])}", "%Y %b %d %H:%M:%S").replace(tzinfo=AST)
        except ValueError:
            continue
        oom_kills.setdefault(m.group(1), []).append(t.replace(year=t.year - 1) if t > now + dt.timedelta(days=1) else t)


out = [f"CONTAINERS ({COMPOSE_PROJECT})"]
CONTAINERS_JSON = os.environ.get("CHESS_HR_TEST_CONTAINERS_JSON")   # test hook (dry-run only): a `docker inspect` array
if CONTAINERS_JSON:
    cinfo = json.load(open(CONTAINERS_JSON)); ids = [c["Id"] for c in cinfo]
else:
    ids = subprocess.run(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={COMPOSE_PROJECT}"],
                         capture_output=True, text=True).stdout.split()
    cinfo = json.loads(subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True).stdout or "[]")
bad = 0; expected_down = []; by_update = []; by_reboot = []
for c in cinfo:
    name = c["Name"].lstrip("/").replace(f"{COMPOSE_PROJECT}-", ""); stt = c["State"]
    health = (stt.get("Health") or {}).get("Status", "-"); rc = c.get("RestartCount", 0)
    if name.rsplit("-", 1)[0] in EXPECTED_STOPPED and stt["Status"] == "exited" and rc == 0:
        expected_down.append(f"{name:24} stopped on purpose ({EXPECTED_STOPPED[name.rsplit('-', 1)[0]]})"); continue
    started = dt.datetime.strptime(stt["StartedAt"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=UTC)
    run = docker_run_at(started, RESTART_BEFORE, RESTART_AFTER) if rc > 0 else None
    oom = max((x for x in oom_kills.get(c["Id"], []) if x <= started + dt.timedelta(seconds=5)), default=None)
    oom = oom if oom and oom >= (run[0] - RESTART_BEFORE if run else started - dt.timedelta(days=1)) else None
    if stt["Status"] == "running" and health != "unhealthy" and rc > 0 and run and not oom:
        by_update.append(f"ℹ️ {name:24} running, restarts {rc} — restarted by Docker update (normal), last start "
                         f"{started.astimezone(AST):%H:%M:%S} AST; update {run_txt(run)}")
    elif (stt["Status"] == "running" and health != "unhealthy" and rc > 0 and not oom
          and (rb := reboot_at(started)) and reboot_quiet_seen(rb)):   # RULE D: last start inside the reboot window
        by_reboot.append(f"ℹ️ {name:24} running, restarts {rc} — restarted while the server rebooted (normal), last start "
                         f"{started.astimezone(AST):%H:%M:%S} AST, no restart since; reboot {reboot_txt(rb)}")
    elif stt["Status"] != "running" or health == "unhealthy" or rc > 0:
        bad += 1
        why = f", last start {started.astimezone(AST):%a %b %d %H:%M} AST, no Docker update then" if rc > 0 and not run else ""
        why += f", OUT OF MEMORY (kernel OOM kill {oom:%a %b %d %H:%M:%S} AST)" if rc > 0 and oom else ""
        out.append(warn(f"container {name}: {stt['Status']}, health {health}, restarts {rc}") +
                   f"{name:24} {stt['Status']}, health {health}, restarts {rc}{why}")
out.insert(1, f"{len(ids)} containers: {len(ids) - bad - len(expected_down) - len(by_update) - len(by_reboot)} running with 0 restarts" +
           (f", {len(by_update)} restarted by Docker update (normal)" if by_update else "") +
           (f", {len(by_reboot)} restarted while the server rebooted (normal)" if by_reboot else "") + ("" if bad else " — all OK"))
out += by_update + by_reboot
out += [f"  {x}" for x in expected_down]
sections.append(out)

# ---------------------------------------------------------------- 5b. versions (added 2026-10-08 with the lila upgrade)
def git_info(repo, *args):
    r = subprocess.run(["git", "--no-optional-locks", "-c", "safe.directory=*", "-C", f"{PROJECT}/repos/{repo}", *args],
                       capture_output=True, text=True)
    return r.stdout.strip() or "?"
def image_of(svc):
    r = subprocess.run(["docker", "inspect", "-f", "{{.Config.Image}}", f"lila-docker-{svc}-1"], capture_output=True, text=True)
    i = r.stdout.strip() or "?"
    return i.split("@sha256:")[0] + "@" + i.split("@sha256:")[1][:12] if "@sha256:" in i else i
try:
    sbt = [l.split("=", 1)[1].strip() for l in open(f"{PROJECT}/repos/lila/project/build.properties") if l.startswith("sbt.version")][0]
except (OSError, IndexError):
    sbt = "?"
out = ["VERSIONS (chess stack; upgraded 2026-10-08, see the upgrade section of CLAUDE.md)",
       f"lila          {git_info('lila', 'log', '-1', '--format=%h %cs')} = upstream {git_info('lila', 'log', '-1', '--format=%h %cs', 'master')}"
       f" + {git_info('lila', 'rev-list', '--count', 'master..HEAD')} local commit(s); sbt {sbt}",
       f"lila-fishnet  {git_info('lila-fishnet', 'log', '-1', '--format=%h %cs')}",
       f"lila-ws       {image_of('lila_ws')}",
       f"fishnet       {image_of('fishnet_play')}",
       f"mongo / redis {image_of('mongodb')} / {image_of('redis')}"]
for svc, repo in (("lila", "lila"), ("lila_fishnet", "lila-fishnet")):
    pdir, binp = PREBUILT[svc]
    ep, running = container_info(svc)
    if not runs_prebuilt(svc):
        out.append(warn(f"{svc} is NOT running its prebuilt app (sbt rollback mode?)") +
                   f"{svc:13} NOT prebuilt — runs {' '.join(map(str, ep))[:60] or '?'} (see CLAUDE.md 'Rebuild lila')"); continue
    info = {}
    try:
        info = dict(l.strip().split("=", 1) for l in open(f"{PROJECT}/{pdir}/current/BUILD-INFO") if "=" in l)
    except OSError:
        pass
    head = git_info(repo, "rev-parse", "HEAD")
    dirty = git_info(repo, "status", "--porcelain", "--untracked-files=no")
    dirty = 0 if dirty == "?" else len(dirty.splitlines())
    built = iso(info["built"]) if "built" in info else None
    row = f"{svc:13} prebuilt from {info.get('commit', '?')[:7]}, built {built.astimezone(AST):%b %d %H:%M} AST" if built else f"{svc:13} prebuilt, BUILD-INFO missing"
    if info.get("commit") != head:
        row = warn(f"{svc}: repos/{repo} is at {head[:7]} but the running build is {info.get('commit', '?')[:7]} — rebuild") + row + \
              f" — repos/{repo} is at {head[:7]}: sudo chess-rebuild-lila.sh {'lila' if svc == 'lila' else 'fishnet'}"
    elif dirty != int(info.get("dirty", "0") or 0):
        row = warn(f"{svc}: repos/{repo} has {dirty} uncommitted edited file(s) (build had {info.get('dirty', '?')}) — rebuild?") + row + \
              f" — {dirty} uncommitted edit(s) now vs {info.get('dirty', '?')} at build time"
    else:
        try:
            cur = os.readlink(f"{PROJECT}/{pdir}/current")
        except OSError:
            cur = "?"
        if running != cur:
            row = warn(f"{svc}: runs {running or '?'} but current is {cur} (rebuilt, not restarted?)") + row + \
                  f" — RUNS {running or '?'}, not current: cd {PROJECT} && docker compose restart {svc}"
    out.append(row)
rb = [i for i in ("lila-docker-lila:rollback-sbt-20261008", "lila-docker-lila_fishnet:rollback-sbt-20261008")
      if subprocess.run(["docker", "image", "inspect", i], capture_output=True).returncode == 0]
if rb or os.path.isdir("/root/prebuilt-switch-20261008"):
    out.append("sbt rollback  kept: " + ", ".join(rb + (["/root/prebuilt-switch-20261008/"] if os.path.isdir("/root/prebuilt-switch-20261008") else [])) +
               (" (until 2026-10-15)" if now < dt.datetime(2026, 10, 15, 22, 0, tzinfo=UTC) else
                " — past 2026-10-15: delete when the owner agrees (CLAUDE.md, prebuilt section)"))
sections.append(out)

# ---------------------------------------------------------------- 5b2. upstream (added 2026-10-28, owner request)
# Read-only: GitHub's public REST API (unauthenticated) + local read-only git. Nothing is fetched or pulled.
GH_ORG, UPGRADE_SUGGEST_DAYS, gh_down = "lichess-org", 60, []
GH_ERRORS = (OSError, ValueError, KeyError, TypeError, AttributeError)


def gh_api(path):
    """JSON of GET https://api.github.com/<path>; OSError on any failure (after a network error the rest fail fast)."""
    if "CHESS_HR_TEST_GITHUB_DIR" in os.environ:
        f = os.path.join(os.environ["CHESS_HR_TEST_GITHUB_DIR"], re.sub(r"[/?&=]", "_", path) + ".json")
        if not os.path.exists(f):
            raise OSError(f"test: no {os.path.basename(f)}")
        return json.load(open(f))
    if gh_down:
        raise OSError(gh_down[0])
    req = urllib.request.Request(f"https://api.github.com/{path}", headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "chess-health-report (chesspuertoricocoffee.com)"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise OSError(f"HTTP {e.code}" + (" — rate limit" if e.headers.get("X-RateLimit-Remaining") == "0" else ""))
    except OSError as e:   # DNS, refused, timeout (URLError is an OSError)
        gh_down.append(f"GitHub API unreachable: {getattr(e, 'reason', e)}")
        raise OSError(gh_down[0])


def git_ok(repo, *a):
    return subprocess.run(["git", "--no-optional-locks", "-c", "safe.directory=*", "-C", f"{PROJECT}/repos/{repo}", *a],
                          capture_output=True).returncode == 0


def git_time(repo, rev):
    t = git_info(repo, "log", "-1", "--format=%cI", rev)
    return None if t == "?" else iso(t)


def patch_shas(repo, adv):
    """Commit ids named in an advisory's patched_versions ('owner/repo@sha' of another repository is skipped)."""
    pv = " ".join(v.get("patched_versions") or "" for v in adv.get("vulnerabilities") or [])
    return [s for r, s in re.findall(r"(?:([\w.-]+/[\w.-]+)@)?\b([0-9a-f]{7,40})\b", pv) if r in ("", f"{GH_ORG}/{repo}")]


def advisories(repo, since, has_commit):
    """(rows, error): security advisories of lichess-org/<repo> published after `since`, each UPGRADE NOW unless fixed."""
    try:
        advs = gh_api(f"repos/{GH_ORG}/{repo}/security-advisories?per_page=100")
        new = sorted((a for a in advs if a.get("state") == "published" and not a.get("withdrawn_at")
                      and a.get("published_at") and iso(a["published_at"]) > since), key=lambda a: a["published_at"])
    except GH_ERRORS as e:
        return [f"{repo:13} security advisories NOT checked ({e})"], e
    rows = []
    for a in new:
        what = (f"{a.get('ghsa_id', '?')} ({a.get('severity') or '?'}), published "
                f"{iso(a['published_at']).astimezone(AST):%Y-%m-%d}: {(a.get('summary') or '').strip()[:90]}")
        fixed = next((s for s in patch_shas(repo, a) if has_commit(s)), None)
        if fixed:
            rows.append(f"ℹ️ {repo}: {what} — already fixed in your build (it contains {fixed[:10]})")
        else:
            rows.append(warn(f"UPGRADE NOW: {repo} security advisory {what} — {a.get('html_url', '')}")
                        + f"{repo}: {what} — {a.get('html_url', '')}")
    return rows or [f"{repo:13} no security advisory published since {since.astimezone(AST):%Y-%m-%d %H:%M} AST "
                    f"({len(advs)} older on record)"], None


out = ["UPSTREAM (GitHub API, read-only: nothing is fetched or pulled; an upgrade stays a deliberate, staged job)"]
# lila: the upstream commit the local branch is based on (origin/master moves only when someone fetches)
bases = {b for b in (git_info("lila", "merge-base", "HEAD", ref) for ref in ("origin/master", "master")) if b != "?"}
base = max(bases, key=lambda b: git_time("lila", b) or dt.datetime.min.replace(tzinfo=UTC)) if bases else None
base_t = git_time("lila", base) if base else None
if not base_t:
    out.append(warn("upstream: lila base commit not found (git merge-base HEAD origin/master or master)") +
               "lila          base commit not found")
else:
    days = (now - base_t).days
    try:
        ahead = gh_api(f"repos/{GH_ORG}/lila/compare/{base}...master?per_page=1")["ahead_by"]
        head = gh_api(f"repos/{GH_ORG}/lila/commits/master")
        up = (f"upstream master {head['sha'][:7]} of {iso(head['commit']['committer']['date']).astimezone(AST):%Y-%m-%d} "
              f"is {ahead} commit(s) ahead")
    except GH_ERRORS as e:
        ahead, up = "?", f"upstream NOT checked ({e})"
    row = (f"lila          base {base[:7]} of {base_t.astimezone(AST):%Y-%m-%d} ({days} days old; UPGRADE SUGGESTED after "
           f"{UPGRADE_SUGGEST_DAYS}) — {up}")
    if days > UPGRADE_SUGGEST_DAYS and ahead != 0:
        row = warn(f"UPGRADE SUGGESTED: the lila base {base[:7]} is {days} days old (over {UPGRADE_SUGGEST_DAYS}); "
                   f"upstream master is {ahead} commits ahead") + row
    out.append(row)

# lila-ws: build time of the running image; its commit = the image-publish run (docker.yml) that was building then
ws_t = ws_sha = None; ws_row = None
img = subprocess.run(["docker", "inspect", "-f", "{{.Image}}", "lila-docker-lila_ws-1"], capture_output=True, text=True).stdout.strip()
c = subprocess.run(["docker", "image", "inspect", "-f", "{{.Created}}", img], capture_output=True, text=True) if img else None
if c and c.returncode == 0 and c.stdout.strip():
    ws_t = iso(re.sub(r"\.\d+", "", c.stdout.strip()))   # RFC 3339 with nanoseconds: Python 3.10 parses whole seconds only
try:
    if not ws_t:
        raise OSError("running lila-ws image not found")
    runs = gh_api(f"repos/{GH_ORG}/lila-ws/actions/workflows/docker.yml/runs?branch=master&status=success&per_page=30")["workflow_runs"]
    mine = ([x for x in runs if iso(x["created_at"]) <= ws_t <= iso(x["updated_at"])] or   # build time is inside its run
            [x for x in runs if iso(x["created_at"]) <= ws_t <= iso(x["updated_at"]) + dt.timedelta(minutes=5)])
    if mine:   # overlapping runs: take the oldest candidate, so a fix is never assumed present
        ws_sha = min(mine, key=lambda x: x["created_at"])["head_sha"]
    of = f" of {ws_sha[:7]}{'?' if len(mine) > 1 else ''}" if ws_sha else ""
    newer = [x for x in runs if iso(x["created_at"]) > ws_t]
    if newer:
        ws_row = (f"lila-ws       newer image: the {iso(newer[0]['updated_at']).astimezone(AST):%Y-%m-%d} build of "
                  f"{newer[0]['head_sha'][:7]}, {len(newer)}{'+' if len(newer) == len(runs) else ''} image build(s) after "
                  f"yours (you run the {ws_t.astimezone(AST):%Y-%m-%d} build{of}); info only")
    else:
        ws_row = f"lila-ws       you run the newest image (the {ws_t.astimezone(AST):%Y-%m-%d} build{of})"
except GH_ERRORS as e:
    ws_row = f"lila-ws       newer image NOT checked ({e})"


def ws_has(sha):
    try:
        return bool(ws_sha) and gh_api(f"repos/{GH_ORG}/lila-ws/compare/{sha}...{ws_sha}")["status"] in ("ahead", "identical")
    except GH_ERRORS:
        return False


failed = []
for repo, since, has in (("lila", base_t, lambda s: git_ok("lila", "merge-base", "--is-ancestor", s, "HEAD")),
                         ("lila-ws", ws_t, ws_has),
                         ("lila-fishnet", git_time("lila-fishnet", "HEAD"),
                          lambda s: git_ok("lila-fishnet", "merge-base", "--is-ancestor", s, "HEAD"))):
    rows, err = advisories(repo, since, has) if since else ([f"{repo:13} security advisories NOT checked (no build date)"], "no build date")
    if err:
        failed.append((repo, err, len(out)))
    out += rows
if failed:
    flag = warn(f"upstream: security advisories NOT checked for {', '.join(r for r, _, _ in failed)} ({failed[0][1]})")
    for _, _, i in failed:
        out[i] = flag + out[i]
out.append(ws_row)

# fishnet: newest GitHub release vs the running image tag
try:
    rel = gh_api(f"repos/{GH_ORG}/fishnet/releases/latest")
    latest, fimg = rel["tag_name"].lstrip("v"), image_of("fishnet_play").split("@")[0]
    cur = fimg.rsplit(":", 1)[1] if ":" in fimg else "?"
    ver = lambda s: tuple(int(x) for x in re.findall(r"\d+", s))
    if cur == "?":
        out.append(f"fishnet       newest release {latest}; running version unknown ({fimg})")
    elif ver(latest) > ver(cur):
        out.append(f"fishnet       {latest} released {iso(rel['published_at']).astimezone(AST):%Y-%m-%d} (you run {cur}); "
                   f"info only — {rel.get('html_url', '')}")
    else:
        out.append(f"fishnet       you run {cur}, the newest release")
except GH_ERRORS as e:
    out.append(f"fishnet       newer release NOT checked ({e})")
sections.append(out)

# ---------------------------------------------------------------- 5c. search (added 2026-10-08)
out = ["SEARCH (Elasticsearch indexes vs MongoDB; fix: sudo chess-search-rebuild.sh --rebuild)"]
try:
    r = subprocess.run(["/usr/local/sbin/chess-search-rebuild.sh"], capture_output=True, text=True, timeout=300)
    rows = [l for l in r.stdout.splitlines() if l.startswith(("OK ", "FAIL "))]
except (OSError, subprocess.TimeoutExpired) as e:
    rows = []; r = None
for l in rows:
    out.append((warn("search: " + l[5:].strip()[:100]) if l.startswith("FAIL") else "") + l)
if not rows:
    out.append(warn("search check did not run") + "search check did not run" + (f" (exit {r.returncode})" if r else ""))
sections.append(out)

# ---------------------------------------------------------------- 5d. blog posts awaiting approval (added 2026-10-08)
out = ["BLOG POSTS AWAITING APPROVAL (open the link as a moderator, click Good or Weak to publish, Spam to reject)"]
r = subprocess.run(["docker", "exec", "lila-docker-mongodb-1", "mongosh", "--quiet", "lichess", "--eval",
                    'print(JSON.stringify(db.ublog_post.find({live:true, "automod.quality":{$exists:false}},'
                    '{title:1, "created.by":1, "lived.at":1}).sort({"lived.at":1}).toArray()))'], capture_output=True, text=True)
try:
    waiting = json.loads(r.stdout.strip().splitlines()[-1])
except (ValueError, IndexError):
    waiting = None
if waiting is None:
    out.append(warn("blog approval check failed") + "could not read the blog posts")
elif not waiting:
    out.append("none waiting")
for w in waiting or []:
    out.append(warn(f"blog post awaits approval: {w.get('title', '?')[:50]}") +
               f"{str(w.get('lived', {}).get('at', '?'))[:10]}  {w.get('title', '?')[:50]} by {w.get('created', {}).get('by', '?')}"
               f" -> https://chesspuertoricocoffee.com/ublog/{w['_id']}/redirect")
sections.append(out)

# ---------------------------------------------------------------- 6. errors, last 7 days
since = (dt.datetime.fromisoformat(os.environ["CHESS_HR_TEST_SINCE"].replace("Z", "+00:00"))
         if "CHESS_HR_TEST_SINCE" in os.environ else now - dt.timedelta(days=7))


# lila's shutdown errors while a Docker update stops it (added 2026-10-20), e.g. 2026-10-15 10:26:45Z:
#   ERROR reactivemongo.api.Cursor Fails to send request / DatabaseException['interrupted at shutdown' (code = 11600)]
#   ERROR socket lila-ws stop / scalalib.future.TimeoutException: Lilakka.shutdown timeout after 1 second
# An entry logged during a Docker update run (STOP_BEFORE/STOP_AFTER, section 5) whose ERROR line says "shutdown", or
# whose text (that line + the exception lines under it) has one of lila's shutdown signatures LILA_SHUTDOWN_RE, is
# listed, not counted. Any other ERROR, then or later, still warns (a bare "shutdown" deeper in a stack trace does not
# count: tested 2026-10-20).
LILA_SHUTDOWN_RE = re.compile(r"interrupted at shutdown|Lilakka\.shutdown|lila-ws stop|MongoConnection is closed|CoordinatedShutdown")
LILA_ERRLOG = os.environ.get("CHESS_HR_TEST_LILA_ERRLOG_GLOB", f"{PROJECT}/repos/lila/logs/error.log*")


def log_entries(path):   # (timestamp, first line, the lines under it) for every timestamped line
    cur = None
    for l in read_all(path):
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", l)
        if m:
            if cur: yield cur
            cur = [m.group(1), l.strip(), ""]
        elif cur and len(cur[2]) < 4000:
            cur[2] += l
    if cur: yield cur


lila_err = []; lila_stop = []; lila_boot = []
lila_entries = [(dt.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").replace(tzinfo=UTC), first, more)
                for path in sorted(glob.glob(LILA_ERRLOG)) for ts, first, more in log_entries(path)]
lila_err_times = [t for t, first, _ in lila_entries if " ERROR " in first]   # all of them, for RULE D's 30-min check
for t, first, more in lila_entries:
        if " ERROR " not in first or t < since:
            continue
        msg = re.sub(r"^\S+ \S+ ERROR\s+", "", first)[:90]
        run = docker_run_at(t, STOP_BEFORE, STOP_AFTER)
        rb = reboot_at(t)
        if run and (re.search(r"shutdown", msg, re.I) or LILA_SHUTDOWN_RE.search(first + "\n" + more)):
            lila_stop.append((run, msg))
        elif (rb and reboot_quiet_seen(rb) and not any(rb[1] + REBOOT_AFTER < x <= rb[1] + REBOOT_AFTER + REBOOT_QUIET
                                                       for x in lila_err_times)):   # RULE D
            lila_boot.append((rb, msg))
        else:
            lila_err.append(msg)
# RULE A (2026-10-28, see the header): emerg/alert/crit within NGINX_PKG_WINDOW of a dpkg install/upgrade of a package
# that restarts nginx -> listed as ℹ️ with the package, not counted. dpkg.log and nginx's error.log are both in local time.
NGINX_ERRLOG = os.environ.get("CHESS_HR_TEST_NGINX_ERRLOG_GLOB", "/var/log/nginx/error.log*")
NGINX_PKG_WINDOW = dt.timedelta(minutes=10)
NGINX_RESTARTING_PLESK = {"plesk-core", "plesk-modsecurity-crs"}


def restarts_nginx(pkg):
    return (bool(re.fullmatch(r"nginx(-core|-common|-full|-light|-extras)?|libnginx-mod-[\w.+-]+|sw-nginx", pkg))
            or "passenger" in pkg or pkg in NGINX_RESTARTING_PLESK)


nginx_pkg_events = []   # (time, action, package, new version)
for l in read_all(DPKG_LOG):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (upgrade|install) ([\w.+-]+):\S+ (\S+) (\S+)", l)
    if m and restarts_nginx(m.group(3)):
        nginx_pkg_events.append((local_time(m.group(1)), m.group(2), m.group(3), m.group(5)))


def nginx_pkg_events_near(t):   # every package event within the window of t, in time order (empty list = none)
    return sorted((e for e in nginx_pkg_events if abs(e[0] - t) <= NGINX_PKG_WINDOW), key=lambda e: e[0])


counts = {"emerg": 0, "alert": 0, "crit": 0, "error": 0}; benign_perm = benign_tls = benign_test = 0; other = []
pkg_explained = []   # (package events in the window, message, time) of emerg/alert/crit lines explained by RULE A
since_ng = since.astimezone(AST).strftime("%Y/%m/%d %H:%M:%S")
for l in read_all(NGINX_ERRLOG):
    if l[:19] < since_ng or not re.match(r"\d{4}/\d\d/\d\d", l):
        continue
    m = re.search(r"\[(emerg|alert|crit|error)\]", l)
    if not m: continue
    lvl = m.group(1)
    if lvl in ("emerg", "crit") and "(13: Permission denied)" in l and "/logs/proxy_" in l: benign_perm += 1; continue
    if lvl == "crit" and re.search(r"SSL_(do_handshake|read|write)\(\) failed", l): benign_tls += 1; continue
    if lvl == "emerg" and re.search(r" in (?!/etc/nginx/)/\S+:\d+", l): benign_test += 1; continue
    if lvl == "emerg" and 'open() "/tmp/claude-' in l: benign_test += 1; continue   # Claude Code test rig (scratch prefix)
    if lvl != "error":
        tn = dt.datetime.strptime(l[:19], "%Y/%m/%d %H:%M:%S").replace(tzinfo=AST)
        evs = nginx_pkg_events_near(tn)
        if evs:
            pkg_explained.append((evs, re.sub(r"^\S+ \S+ ", "", l.strip())[:110], tn)); continue
    counts[lvl] += 1
    if lvl != "error": other.append(re.sub(r"^\S+ \S+ ", "", l.strip())[:110])
out = ["ERRORS (last 7 days)"]
flag = warn(f"{len(lila_err)} lila ERROR lines") if lila_err else ""
out.append(f"{flag}lila error.log: {len(lila_err)} ERROR lines")
for msg, n in sorted({m: lila_err.count(m) for m in lila_err}.items(), key=lambda kv: -kv[1])[:3]:
    out.append(f"    {n} × {msg}")
for run in sorted({r for r, _ in lila_stop}):
    msgs = [m for r, m in lila_stop if r == run]
    out.append(f"ℹ️ {len(msgs)} lila shutdown ERROR line{'s' if len(msgs) != 1 else ''} while a Docker update restarted the "
               f"containers (normal, not counted) — update {run_txt(run)}")
    out.append("    " + "; ".join(sorted(set(msgs))))
for rb in sorted({r for r, _ in lila_boot}):
    msgs = [m for r, m in lila_boot if r == rb]
    out.append(f"ℹ️ {len(msgs)} lila ERROR line{'s' if len(msgs) != 1 else ''} while the server rebooted (normal, not counted; "
               f"none in the 30 min after) — reboot {reboot_txt(rb)}")
    out.append("    " + "; ".join(sorted(set(msgs))))
unexpected = counts["emerg"] + counts["alert"] + counts["crit"]
flag = warn(f"{unexpected} unexpected nginx emerg/alert/crit lines") if unexpected else ""
out.append(f"{flag}nginx error.log: {unexpected} unexpected emerg/alert/crit, {counts['error']} [error]")
for msg in other[-3:]:
    out.append(f"    {msg}")
out.append(f"    known benign (not counted): {benign_perm} lines from the nightly logrotate: nginx workers can't reopen Plesk per-site "
           f"logs (harmless); {benign_tls} client TLS aborts; "
           f"{benign_test} config tests of files outside /etc/nginx")
if pkg_explained:
    out.append(f"ℹ️ {len(pkg_explained)} emerg/alert/crit line(s) within {NGINX_PKG_WINDOW.seconds // 60} min of an update of a "
               f"package that restarts nginx (normal, not counted):")
    i = 0
    while i < len(pkg_explained):   # consecutive lines with the same package events share one reason line
        evs, j = pkg_explained[i][0], i
        while j < len(pkg_explained) and pkg_explained[j][0] == evs:
            out.append(f"    {pkg_explained[j][2]:%a %b %d %H:%M:%S} AST  {pkg_explained[j][1]}"); j += 1
        out.append(f"      <- {len(evs)} package event(s) within {NGINX_PKG_WINDOW.seconds // 60} min, in time order: "
                   + "; ".join(f"{e[0]:%H:%M:%S} {e[1]} {e[2]} {short_ver(e[3])}" for e in evs))
        i = j
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
# RULE B (added 2026-10-28): an ERROR that is "Lock could not be acquired" (another package manager - typically Plesk's
# installer - held the apt lock) is listed with ℹ️, not counted, ONLY when a later unattended-upgrades run started within
# 24 h of it finished cleanly: no ERROR/CRITICAL line, and a completion line (UU_DONE_RE). Any other ERROR, and a lock
# error with no such run, still warns.
UU_LOG = os.environ.get("CHESS_HR_TEST_UU_GLOB", "/var/log/unattended-upgrades/unattended-upgrades.log*")
UU_LOCK_RE = re.compile(r"lock\W+could\W*n[o']?t\W+be\W+acquired", re.I)
UU_DONE_RE = re.compile(r"No packages found that can be upgraded unattended|All upgrades installed|Packages that were upgraded", re.I)
uu_runs = []   # chronological runs: start time, ERROR/CRITICAL count, completion line seen
for tl_, lv_, msg_ in sorted((dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST), m.group(2), m.group(3))
                             for m in (re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\d+ (\w+) (.*)", l) for l in read_all(UU_LOG)) if m):
    if "Starting unattended upgrades script" in msg_:
        uu_runs.append({"start": tl_, "errors": 0, "done": False})
    elif uu_runs:
        if lv_ in ("ERROR", "CRITICAL"): uu_runs[-1]["errors"] += 1
        if UU_DONE_RE.search(msg_): uu_runs[-1]["done"] = True


def uu_clean_run_after(t):
    return next((r for r in uu_runs if t < r["start"] <= t + dt.timedelta(hours=24) and r["done"] and not r["errors"]), None)


uu_prompt, uu_err, uu_kept, uu_last, uu_lock_ok = set(), [], set(), None, []
for l in read_all(UU_LOG):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\d+ (\w+) (.*)", l)
    if not m: continue
    tl = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=AST)
    if tl < since: continue
    if "Starting unattended upgrades script" in m.group(3): uu_last = max(uu_last or tl, tl)
    pm = re.match(r"Package (\S+) has conffile prompt", m.group(3))
    if pm: uu_prompt.add(pm.group(1))
    if m.group(2) == "ERROR":
        clean = uu_clean_run_after(tl) if UU_LOCK_RE.search(m.group(3)) else None
        if clean: uu_lock_ok.append((tl, m.group(3)[:100], clean["start"]))
        else: uu_err.append(m.group(3)[:100])
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
for tl, msg, clean_start in uu_lock_ok:
    out.append(f"ℹ️ unattended-upgrades ERROR {tl:%a %b %d %H:%M} AST: {msg} — another package manager held the apt lock; "
               f"the next run ({clean_start:%a %b %d %H:%M} AST) finished cleanly (normal, not counted)")
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

# ---------------------------------------------------------------- 11-13. (public copy: the checks of other sites on this server are omitted)

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
