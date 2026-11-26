#!/bin/bash
# chess-mongodump.sh — nightly logical backup of the chesspuertoricocoffee.com MongoDB
#
# Added 2026-10-02 (fix item 13, /opt/chess/lila-docker/fixes-2026-10-02.md).
# BUTTON 256 (2026-11-26, owner; Codex review item 13): a LOCK, private temp files, EVERY failure on stderr (cron mails) + logged,
# and a REAL check: the new archive is restored into a THROWAWAY MongoDB (its own container: no network, data in memory, removed
# when it stops) and every collection NAME and its document COUNT is compared with the live database.
# Why: the old check grepped mongorestore's --dryRun text; mongorestore 100.20 (MongoDB 7.0.48, BUTTON 241) prints the names in
# backquotes, the grep found nothing, `set -e` ended the script on 2026-11-26 01:15 with NO log line and NO mail (a .partial was left).
#
# - Dumps every database except `local` from the live mongodb container (checked: compose project lila-docker, service mongodb,
#   running) as one gzip archive: /var/backups/chess-mongo/chess-mongo-YYYYMMDD-HHMM.archive.gz (600). Written to a private
#   dot-temp file first; only a dump that passed every check gets its real name. A failed one is kept as <name>.FAILED-<pid> (600).
#   The check covers the chess database `lichess` (admin/config hold no chess data). Live counts are taken right after the dump.
# - Deletes nothing except: dumps older than 14 days with EXACTLY this script's name pattern, only after a good dump (and not when
#   CHESS_MONGODUMP_NO_PRUNE=1, which the BUTTON 256 installer uses for its test dump). Throwaway containers remove themselves (--rm).
# - One log line per run in /var/log/chess-mongodump.log: "OK <file> size=.. lichess_collections=.. verified=yes ..." or "FAIL <why>".
#   The weekly health report and chess-search-rebuild.sh read the OK line - keep its first five fields exactly as they are.
# - Never two at once: flock /run/lock/chess-mongodump.lock (a second run FAILs at once). Under the lock, throwaway containers of an
#   earlier killed run are stopped first and dot-temp files of a killed run are renamed <name>.FAILED-stale (counted in the OK line).
# - Every good dump also gets <name>.manifest (600): its collection names + document counts as restored. Pruned with its dump.
#
#   sudo chess-mongodump.sh                       a dump now (same as the 01:15 cron)
#   sudo chess-mongodump.sh --check-archive FILE  restore FILE into a throwaway MongoDB. Verdict: the restore must equal FILE.manifest
#                                                 exactly (older dumps without a manifest: compared with live, or checked alone if
#                                                 live does not answer - weaker). Always also prints live vs archive ("IDENTICAL"
#                                                 after a restore). Writes NO log line, changes nothing.
# Restore (DESTRUCTIVE): see PANIC-BUTTONS BUTTON 5.

set -Eeuo pipefail
umask 077
TMP=""; CHK=""; MSG=""; DONE=0; STAGE=start; ERRAT=""; MODE=dump; ARCH=""; OUT=""
DIR=/var/backups/chess-mongo
LOG=/var/log/chess-mongodump.log
LOCK=/run/lock/chess-mongodump.lock
LIVE_CT=lila-docker-mongodb-1          # the live mongodb container: only dumped and counted, never written to
KEEP_DAYS=14
BREAK=""; LABELV=prod                   # the throwaway's label value: a run only ever cleans up throwaways of its own kind
# @TEST-HOOKS@ (BUTTON 256 test builds insert their hooks on this line; the installed script has NONE)

log() {   # one line in the dump log (dump mode only); a log that cannot be written is said on stderr
  [ "$MODE" = dump ] || return 0
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || echo "chess-mongodump: could not write $LOG" >&2
  return 0
}
fail() { MSG=$*; exit 1; }
gone() {   # 0 when no container named $1 exists (and docker answered)
  local o; o=$(timeout 20 docker ps -aq --filter "name=^$1\$" 2>/dev/null) || return 1; [ -z "$o" ]
}
stop_chk() {   # stop the throwaway (Docker removes it: --rm) and VERIFY it is gone; 0 = gone
  [ -n "$CHK" ] || return 0
  timeout 60 docker stop -t 5 "$CHK" >/dev/null 2>&1 || timeout 60 docker rm -f "$CHK" >/dev/null 2>&1 || true
  local i; for i in $(seq 1 20); do gone "$CHK" && { CHK=""; return 0; }; sleep 1; done
  return 1
}
trap 'ERRAT="line $LINENO: $BASH_COMMAND"' ERR
on_exit() {
  local rc=$? kept=""
  trap - ERR
  set +e
  if [ -n "$CHK" ] && ! stop_chk; then
    [ "$DONE" = 1 ] && { DONE=0; MSG="the dump is good but its throwaway container $CHK could not be removed"; }
    MSG="${MSG:+$MSG; }throwaway container $CHK is still there"
  fi
  if [ "$DONE" != 1 ]; then
    [ -n "$MSG" ] || MSG="unexpected exit rc=$rc at stage $STAGE (${ERRAT:-no command recorded})"
    if [ -n "$TMP" ] && [ -e "$TMP" ]; then
      kept="$OUT.FAILED-$$"
      if [ ! -e "$kept" ] && mv -n "$TMP" "$kept" 2>/dev/null && [ ! -e "$TMP" ]; then MSG="$MSG (dump kept as $kept)"
      else MSG="$MSG (dump left as $TMP)"; fi
    fi
    echo "chess-mongodump: FAIL $MSG" >&2
    log "FAIL $MSG"
    [ "$rc" != 0 ] || rc=1
  fi
  exit "$rc"
}
trap on_exit EXIT

case "${1:-}" in
  "") [ $# -eq 0 ] || { MODE=check; fail "usage: chess-mongodump.sh [--check-archive FILE]"; };;
  --check-archive) MODE=check; [ $# -eq 2 ] && [ -f "$2" ] || fail "usage: chess-mongodump.sh --check-archive FILE (an existing file)"; ARCH=$2;;
  *) MODE=check; fail "usage: chess-mongodump.sh [--check-archive FILE]";;
esac
[ "$(id -u)" = 0 ] || fail "run as root"
TS=$(date +%Y%m%d-%H%M)
OUT="$DIR/chess-mongo-$TS.archive.gz"

exec 9>>"$LOCK"
flock -n 9 || fail "another chess-mongodump.sh is running (lock $LOCK)"

STAGE="clean up after a killed run"
stale=$(timeout 30 docker ps -aq --filter "label=chess-dumpcheck=$LABELV") || fail "docker ps does not answer"
for c in $stale; do timeout 60 docker stop -t 5 "$c" >/dev/null 2>&1 || timeout 60 docker rm -f "$c" >/dev/null 2>&1 || true; done
if [ -n "$stale" ]; then
  sleep 2; left=$(timeout 30 docker ps -aq --filter "label=chess-dumpcheck=$LABELV") || fail "docker ps does not answer"
  [ -z "$left" ] || fail "throwaway container(s) of a killed run could not be removed: $left"
fi
nstale=0
if [ "$MODE" = dump ]; then
  for f in "$DIR"/.chess-mongo-*.partial; do
    [ -e "$f" ] || continue
    if [ ! -e "$f.FAILED-stale" ] && mv -n "$f" "$f.FAILED-stale" && [ ! -e "$f" ]; then nstale=$((nstale + 1)); else fail "could not set aside the stale temp file $f"; fi
  done
fi

# collection<TAB>count for every non-system collection of `lichess`, sorted; "$@" = how to reach mongosh
LIST_JS='db.getCollectionInfos({type:"collection"}).map(i=>i.name).filter(n=>!n.startsWith("system.")).sort().forEach(n=>print(n+"\t"+db.getCollection(n).countDocuments({})))'
counts() { timeout 120 "$@" mongosh --quiet lichess --eval "$LIST_JS" | tr -d '\r'; }

# compare. stdin = live, restored, manifest listings separated by "=====" lines (live / manifest may be empty); argv[1] = nightly | check
#   nightly: restored vs live - same names, counts within max(10, 1 %), nothing non-empty live is empty, > 0 documents
#   check:   restored vs the archive's manifest - IDENTICAL; without a manifest: vs live (same names, nothing non-empty live is empty);
#            without both: >= 1 collection and >= 1 document (weak). Always also prints live vs archive (for after a restore).
COMPARE_PY='
import sys
mode = sys.argv[1]
live_t, rest_t, man_t = sys.stdin.read().split("\n=====\n")
def parse(t):
    d = {}
    for l in t.splitlines():
        if l.strip() and not l.startswith("#"):
            n, c = l.rsplit("\t", 1); d[n] = int(c)
    return d
live, rest, man = parse(live_t), parse(rest_t), parse(man_t)
bad, far = [], []
docs = sum(rest.values())
if not rest: bad.append("the archive restored no collection")
if docs == 0: bad.append("the archive restored 0 documents")
def names_counts(ref, label, tol):
    for n in sorted(set(ref) - set(rest)): bad.append(f"missing in archive (in {label}): {n}")
    for n in sorted(set(rest) - set(ref)): bad.append(f"in archive but not in {label}: {n}")
    for n in sorted(set(ref) & set(rest)):
        a, b = ref[n], rest[n]
        if a > 0 and b == 0: bad.append(f"{n}: empty in archive, {a} in {label}")
        elif tol is not None and abs(a - b) > tol(a): far.append(f"{n}: {label} {a}, archive {b}")
if mode == "nightly":
    basis = "live (right after the dump)"
    if not live: bad.append("live lichess lists no collections")
    names_counts(live, "live", lambda a: max(10, a // 100)); bad += far
elif man:
    basis = "the archive\x27s own manifest (must be identical)"
    names_counts(man, "manifest", lambda a: 0); bad += far
elif live:
    basis = "live (this dump has no manifest - weaker)"
    names_counts(live, "live", None)
else:
    basis = "the archive alone (no manifest, live not readable - WEAK: only >= 1 collection and >= 1 document)"
print(f"verdict basis: {basis}")
print(f"archive: collections={len(rest)} documents={docs}" + (f"; manifest: collections={len(man)} documents={sum(man.values())}" if man else ""))
if not live:
    print("live vs archive: live database not readable")
else:
    d = [f"only live: {n}" for n in sorted(set(live) - set(rest))] + [f"only archive: {n}" for n in sorted(set(rest) - set(live))]
    d += [f"{n}: live {live[n]}, archive {rest[n]}" for n in sorted(set(live) & set(rest)) if live[n] != rest[n]]
    print("live vs archive: IDENTICAL (every collection name and count)" if not d else f"live vs archive: {len(d)} difference(s)")
    for x in d[:15]: print("  differs:", x)
for x in bad[:20]: print("  PROBLEM:", x)
sys.exit(1 if bad else 0)
'

live_ok() {   # the live container is lila-docker's running mongodb service
  [ "$(timeout 30 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}/{{.State.Running}}' "$LIVE_CT" 2>/dev/null)" = "lila-docker/mongodb/true" ]
}

restore_check() {   # $1 archive, $2 nightly|check, $3 live listing ("" = not readable), $4 manifest ("" = none) -> CMP, CMPOK, REST
  local img i rout
  img=$(timeout 30 docker inspect -f '{{.Image}}' "$LIVE_CT" 2>/dev/null) \
    || img=$(timeout 30 docker image inspect -f '{{.Id}}' "$(sed -nE 's/^ +image: (mongo:[^ ]+) *$/\1/p' /opt/chess/lila-docker/compose.yml | head -n 1)") \
    || fail "cannot find the MongoDB image (live container gone and compose.yml's mongo image not on this host)"
  STAGE="start throwaway MongoDB"
  CHK=chess-dumpcheck-$$
  timeout 120 docker run -d --rm --name "$CHK" --label "chess-dumpcheck=$LABELV" --network none --memory 1g \
      --tmpfs /data/db:rw,size=1g --tmpfs /data/configdb:rw,size=16m \
      --entrypoint timeout "$img" 900 mongod --bind_ip 127.0.0.1 --wiredTigerCacheSizeGB 0.25 --quiet >/dev/null \
    || fail "could not start the throwaway MongoDB"
  for i in $(seq 1 60); do
    [ "$(timeout 10 docker exec "$CHK" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | tr -d '\r')" = 1 ] && break
    [ "$i" -lt 60 ] || fail "the throwaway MongoDB did not answer within 60 s"
    sleep 1
  done
  [ "$(timeout 30 docker inspect -f '{{.HostConfig.NetworkMode}}' "$CHK")" = none ] || fail "the throwaway MongoDB is not isolated"
  STAGE="restore into the throwaway MongoDB"
  rout=$(timeout 600 docker exec -i "$CHK" mongorestore --archive --gzip --stopOnError --nsInclude='lichess.*' < "$1" 2>&1) \
    || fail "restore into the throwaway MongoDB failed: $(tail -n 2 <<<"$rout" | tr '\n' ' ' | cut -c1-300)"
  grep -qE '[0-9]+ document\(s\) restored successfully\. 0 document\(s\) failed to restore\.' <<<"$rout" \
    || fail "restore summary not clean: $(grep -E 'document\(s\)' <<<"$rout" | tail -n 1 | cut -c1-200)"
  [ "$BREAK" != drop-collection ] || timeout 30 docker exec "$CHK" mongosh --quiet lichess --eval 'db.getCollection(db.getCollectionNames().sort()[0]).drop()' >/dev/null
  STAGE="compare"
  REST=$(counts docker exec "$CHK") || fail "cannot list the restored collections"
  if CMP=$(printf '%s\n=====\n%s\n=====\n%s\n' "$3" "$REST" "$4" | python3 -I -c "$COMPARE_PY" "$2"); then CMPOK=1; else CMPOK=0; fi
  stop_chk || fail "the throwaway container $CHK could not be removed"
}

if [ "$MODE" = check ]; then
  live=""; if live_ok; then live=$(counts docker exec "$LIVE_CT") || live=""; fi
  man=""; if [ -f "$ARCH.manifest" ] && [ ! -L "$ARCH.manifest" ]; then man=$(cat "$ARCH.manifest") || fail "cannot read $ARCH.manifest"; fi
  restore_check "$ARCH" check "$live" "$man"
  echo "$CMP"
  [ "$CMPOK" = 1 ] || fail "check of $ARCH: see the PROBLEM lines"
  DONE=1; echo "CHECK PASS: $ARCH restores cleanly into a throwaway MongoDB (live untouched)"; exit 0
fi

install -d -m 700 "$DIR"
STAGE="find the live MongoDB"
live_ok || fail "$LIVE_CT is not lila-docker's running mongodb container"
STAGE=mongodump
TMP=$(mktemp "$DIR/.chess-mongo-$TS.XXXXXX.partial")
timeout 900 docker exec "$LIVE_CT" mongodump --quiet --archive --gzip > "$TMP" 2>>"$LOG" || fail "mongodump exited non-zero"
STAGE="live counts"
live=$(counts docker exec "$LIVE_CT") || fail "cannot list the live lichess collections"
[ -n "$live" ] || fail "the live lichess database lists no collections"
[ "$BREAK" != bad-gzip ] || truncate -s 100000 "$TMP"
[ "$BREAK" != unexpected ] || false
STAGE="gzip test"
gzip -t "$TMP" 2>>"$LOG" || fail "gzip integrity check failed"
restore_check "$TMP" nightly "$live" ""
[ "$CMPOK" = 1 ] || fail "read-back mismatch: $(tr '\n' ' ' <<<"$CMP" | cut -c1-400)"
STAGE=keep
[ ! -e "$OUT" ] && [ ! -e "$OUT.manifest" ] || fail "$OUT (or its manifest) already exists (another dump this minute) - not overwritten"
docs=$(sed -nE 's/^archive: collections=[0-9]+ documents=([0-9]+).*/\1/p' <<<"$CMP" | head -n 1)
[[ "$docs" =~ ^[1-9][0-9]*$ ]] || fail "cannot read the document count of the check"
ncoll=$(grep -c . <<<"$live")
MAN="$OUT.manifest"; MTMP="$DIR/.chess-mongo-$TS.$$.manifest.partial"     # the manifest is complete BEFORE the dump gets its name
{ echo "# chess-mongodump manifest v1 $(basename "$OUT") collections=$(grep -c . <<<"$REST") documents=$docs"; printf '%s\n' "$REST"; } > "$MTMP" \
  || fail "could not write the manifest"
mv -n "$TMP" "$OUT" && [ ! -e "$TMP" ] && [ -f "$OUT" ] || fail "could not rename the dump to $OUT"
TMP=""
mv -n "$MTMP" "$MAN" && [ ! -e "$MTMP" ] && [ -f "$MAN" ] || fail "the dump $OUT is good but its manifest stays as $MTMP (rename failed)"
chmod 600 "$OUT" "$MAN"
size=$(stat -c %s "$OUT") && [[ "$size" =~ ^[1-9][0-9]*$ ]] || fail "cannot read the size of $OUT"
deleted=0
if [ "${CHESS_MONGODUMP_NO_PRUNE:-}" != 1 ]; then
  deleted=$(find "$DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/chess-mongo-[0-9]{8}-[0-9]{4}\.archive\.gz(\.manifest)?' \
            -mtime +$((KEEP_DAYS - 1)) -print -delete | grep -c '\.archive\.gz$' || true)
fi
ts=$(date -u +%FT%TZ) && [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "the dump is good ($OUT) but date failed"
line="OK $OUT size=$size lichess_collections=$ncoll verified=yes restore_check=throwaway documents=$docs pruned=$deleted stale_partials=$nstale"
printf '%s %s\n' "$ts" "$line" >> "$LOG" || fail "the dump is good ($OUT) but the OK line could not be written to $LOG"
DONE=1
