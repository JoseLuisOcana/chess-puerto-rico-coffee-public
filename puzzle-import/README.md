# puzzle-import

Imports the public Lichess puzzle database into the local MongoDB for use by
our Chess Puerto Rico Coffee deployment.

## Dataset source

- Puzzle database index: https://database.lichess.org/#puzzles
- Direct download (compressed): https://database.lichess.org/lichess_db_puzzle.csv.zst

## Usage

1. Download and decompress the dataset:

   ```
   curl -LO https://database.lichess.org/lichess_db_puzzle.csv.zst
   zstd -d lichess_db_puzzle.csv.zst
   ```

2. Run the importer (requires `pymongo`):

   ```
   python3 import_puzzles.py --csv lichess_db_puzzle.csv
   ```

   Default CSV path is `/tmp/lichess_db_puzzle.csv`; override with `--csv PATH`.
   See `python3 import_puzzles.py --help` for all options (batch size, test
   collection name, row limit, etc.).

   MongoDB connection is taken from the standard `MONGO_URI` / `MONGODB_URI`
   environment variables as expected by `pymongo.MongoClient()`.

## Not included in this repository

The `.csv` (~1 GB uncompressed) and `.csv.zst` (~280 MB compressed) files are
intentionally NOT committed to this repo — they exceed GitHub's 100 MB
per-file limit and are freely downloadable from the source above.

`*.csv` and `*.csv.zst` are in the repository's `.gitignore` to prevent
accidental commits.

## License

This script is licensed under AGPL-3.0, matching the rest of this repository.
Although it is standalone utility code (it does not link to or derive from
lila source), the repository license is kept uniform for simplicity.
