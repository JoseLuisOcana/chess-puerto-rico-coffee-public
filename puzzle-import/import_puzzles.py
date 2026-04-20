#!/usr/bin/env python3
"""
Import Lichess puzzle CSV into MongoDB puzzle2_puzzle collection.

Schema (matches lila's BsonHandlers.scala puzzleReader):
  _id:    PuzzleId (string)
  gameId: extracted from GameUrl
  fen:    FEN (string)
  line:   Moves (space-separated UCI string, stored as-is)
  glicko: { r: Rating (float), d: RatingDeviation (float), v: 0.09 }
  plays:  NbPlays (int)
  vote:   Popularity / 100.0 (float)
  themes: Themes.split() (list of strings)
  opening: OpeningTags.split() (list) -- OMITTED when empty

Usage:
  python3 import_puzzles.py --csv /tmp/lichess_db_puzzle.csv
  python3 import_puzzles.py --csv /tmp/x.csv --limit 100 --coll puzzle2_puzzle_test
"""
import argparse
import csv
import re
import sys
import time
from pymongo import MongoClient, InsertOne, WriteConcern
from pymongo.errors import BulkWriteError

GAME_URL_RE = re.compile(r"^https?://lichess\.org/([^/#]+)")


def parse_row(row):
    m = GAME_URL_RE.match(row["GameUrl"])
    game_id = m.group(1) if m else ""
    if len(game_id) > 8:
        game_id = game_id[:8]

    doc = {
        "_id": row["PuzzleId"],
        "gameId": game_id,
        "fen": row["FEN"],
        "line": row["Moves"],
        "glicko": {
            "r": float(row["Rating"]),
            "d": float(row["RatingDeviation"]),
            "v": 0.09,
        },
        "plays": int(row["NbPlays"]),
        "vote": float(row["Popularity"]) / 100.0,
        "themes": row["Themes"].split() if row["Themes"] else [],
    }
    openings = row["OpeningTags"].split() if row["OpeningTags"] else []
    if openings:
        doc["opening"] = openings
    return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="/tmp/lichess_db_puzzle.csv",
                        help="Path to the decompressed Lichess puzzle CSV")
    parser.add_argument("--uri", default="mongodb://127.0.0.1:27017",
                        help="MongoDB URI")
    parser.add_argument("--db", default="lichess",
                        help="Target database name")
    parser.add_argument("--coll", default="puzzle2_puzzle",
                        help="Target collection name")
    parser.add_argument("--batch", type=int, default=1000,
                        help="Bulk insert batch size")
    parser.add_argument("--sleep", type=float, default=0.1,
                        help="Seconds to sleep between batches (WT eviction window)")
    parser.add_argument("--limit", type=int, default=0,
                        help="If >0, import only the first N rows (dry-run mode)")
    args = parser.parse_args()

    # w=1, j=false: acknowledged by primary but no journal fsync per batch.
    # Acceptable because import is idempotent via unique _id on retry.
    client = MongoClient(args.uri, w=1, journal=False)
    coll = client[args.db][args.coll]

    print(f"Importing {args.csv}")
    print(f"  -> {args.db}.{args.coll}")
    if args.limit > 0:
        print(f"  DRY-RUN: limited to first {args.limit} rows")
    print()

    start = time.time()
    batch = []
    total = 0
    errors = 0
    dup_errors = 0

    def flush():
        nonlocal errors, dup_errors
        if not batch:
            return
        try:
            coll.bulk_write(batch, ordered=False)
        except BulkWriteError as bwe:
            write_errors = bwe.details.get("writeErrors", [])
            dup = sum(1 for e in write_errors if e.get("code") == 11000)
            other = len(write_errors) - dup
            dup_errors += dup
            errors += other
            if other > 0:
                print(f"  bulk error: {other} non-duplicate write errors", file=sys.stderr)
                for e in write_errors[:3]:
                    if e.get("code") != 11000:
                        print(f"    {e}", file=sys.stderr)

    with open(args.csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                batch.append(InsertOne(parse_row(row)))
            except (ValueError, KeyError) as e:
                errors += 1
                if errors <= 5:
                    print(f"  parse error row {total+1}: {e}", file=sys.stderr)
                continue

            if len(batch) >= args.batch:
                flush()
                total += len(batch)
                batch = []
                if args.sleep > 0:
                    time.sleep(args.sleep)
                if total % 50000 == 0:
                    rate = total / (time.time() - start)
                    eta = (5882680 - total) / rate if rate > 0 else 0
                    print(f"  inserted {total:>9,}  ({rate:>7,.0f} docs/sec, eta {eta/60:5.1f} min)", flush=True)

            if args.limit > 0 and total + len(batch) >= args.limit:
                break

    if batch:
        flush()
        total += len(batch)

    elapsed = time.time() - start
    count = coll.count_documents({})
    print()
    print(f"Done in {elapsed:,.1f}s")
    print(f"  Rows processed:  {total:,}")
    print(f"  Parse errors:    {errors:,}")
    print(f"  Duplicate keys:  {dup_errors:,}  (idempotent re-run)")
    print(f"  Collection count: {count:,}")


if __name__ == "__main__":
    main()
