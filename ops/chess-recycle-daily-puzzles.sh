#!/bin/bash
# chess-recycle-daily-puzzles.sh — keep /training/daily alive on chesspuertoricocoffee.com
#
# Added 2026-10-02 (site audit, /opt/chess/lila-docker/audit-2026-10-02.md §7).
#
# Why: only the 3,000 lila-db-seed puzzles are loaded. lila's daily selector
# (repos/lila/modules/puzzle/src/main/DailyPuzzle.scala) only draws from the 37
# puzzles in the three `mix|top` puzzle2_path docs that overlap rating 2150-2300,
# and never picks a puzzle whose `day` field is already set. All 37 had been used
# by 2026-05-18, so from ~2026-05-19 `Found(None)` made /training/daily (and
# /api/puzzle/daily, and the homepage puzzle widget) return 404.
#
# What: unset `day` on puzzles that were the daily more than $DAYS days ago, so
# they become eligible again. DAYS=30 < 37 keeps >= 7 eligible at any time.
#
# REMOVE THIS (and /etc/cron.d/chess-daily-puzzle-recycle) after the full Lichess
# puzzle import: with ~5.9M puzzles lila never runs dry, and recycling would only
# cause early repeats.
#
# Usage: chess-recycle-daily-puzzles.sh [--dry-run]   (--dry-run changes nothing)

set -euo pipefail

DAYS=30
LOG=/var/log/chess-daily-puzzle-recycle.log
DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true

cd /opt/chess/lila-docker

out=$(/usr/bin/docker compose exec -T mongodb mongosh --quiet lichess --eval "
  const cutoff = new Date(Date.now() - ${DAYS} * 864e5);
  const sel = { day: { \$lt: cutoff } };
  if (${DRY}) {
    print('dry-run would_recycle=' + db.puzzle2_puzzle.countDocuments(sel) + ' cutoff=' + cutoff.toISOString());
  } else {
    const r = db.puzzle2_puzzle.updateMany(sel, { \$unset: { day: '' } });
    print('recycled=' + r.modifiedCount + ' cutoff=' + cutoff.toISOString());
  }
  print('eligible_dated_last_' + ${DAYS} + 'd=' + db.puzzle2_puzzle.countDocuments({ day: { \$gte: cutoff } }));
" | tr '\n' ' ')

line="$(date -u +%FT%TZ) ${out}"
if $DRY; then
  echo "$line"
else
  echo "$line" >> "$LOG"
fi
