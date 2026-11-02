#!/bin/bash
# chess-bgjobs-cleanup.sh — delete stale sbt classpath copies left by lila / lila-fishnet restarts.
#
# Every `sbt run` copies the classpath into repos/<repo>/target/bg-jobs/sbt_<id> and never
# removes it when the JVM is killed by a container restart. By 2026-10-02: lila 62 copies
# (~175 MB each, 10.8 GB), lila-fishnet 41 (2.1 GB). Covers both (DIRS below).
#
# Keeps:  every sbt_* folder referenced by ANY running process (fd, mmap, cmdline,
#         cwd — host /proc, so processes inside the lila container are included),
#         and any folder modified in the last 60 min (a lila start in progress).
# Fail-safe: if no running process uses bg-jobs at all, deletes nothing.
# Usage:  chess-bgjobs-cleanup.sh [--dry-run]     Log: /var/log/chess-bgjobs-cleanup.log
set -u
DIRS=(/opt/chess/lila-docker/repos/lila/target/bg-jobs /opt/chess/lila-docker/repos/lila-fishnet/target/bg-jobs)
LOG=/var/log/chess-bgjobs-cleanup.log
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
TAG=$([ $DRY = 1 ] && echo "[dry-run] " || true)
log() { echo "$(date '+%F %T %Z') ${TAG}$*" | tee -a "$LOG"; }

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

inuse=$(for p in /proc/[0-9]*; do
          { tr '\0' '\n' < "$p/cmdline"; readlink "$p/cwd"; ls -l "$p/fd/"; cat "$p/maps"; } 2>/dev/null
        done | grep -oE 'bg-jobs/sbt_[0-9a-f]+' | sed 's|^bg-jobs/||' | sort -u)

if [ -z "$inuse" ]; then
  log "SKIP: no running process uses bg-jobs (lila down, or detection failed) — nothing deleted"
  exit 0
fi
log "in use: $(echo $inuse)"

freed=0; n=0; kept_recent=0
for DIR in "${DIRS[@]}"; do
[ -d "$DIR" ] || { log "SKIP: $DIR missing"; continue; }
for d in "$DIR"/sbt_*; do
  [ -d "$d" ] || continue
  name=${d##*/}
  [[ $name =~ ^sbt_[0-9a-f]+$ ]] || { log "skip odd name: $name"; continue; }
  grep -qx "$name" <<<"$inuse" && continue
  if [ -n "$(find "$d" -maxdepth 0 -mmin -60)" ]; then kept_recent=$((kept_recent+1)); log "keep (modified <60 min): $name"; continue; fi
  kb=$(du -sk "$d" | cut -f1)
  if [ $DRY = 1 ]; then log "would delete ${DIR#/opt/chess/lila-docker/repos/}/$name ($((kb/1024)) MB, $(stat -c %y "$d" | cut -c1-16))"
  else rm -rf -- "$d" && log "deleted ${DIR#/opt/chess/lila-docker/repos/}/$name ($((kb/1024)) MB)"; fi
  freed=$((freed+kb)); n=$((n+1))
done
done
log "done: $n folder(s), $((freed/1024)) MB $([ $DRY = 1 ] && echo 'would be ' || true)freed; kept $(echo "$inuse" | wc -l) in use + $kept_recent recent"
