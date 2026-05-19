#!/usr/bin/env python3
"""Build LiveChess/Resources/puzzles_starter.json from the public
Lichess puzzle database (https://database.lichess.org).

The Lichess REST `/api/puzzle/next` endpoint is rate-limited per IP
(unauth) or per token (auth), and the sim + dev machine share an IP
during development — so seeding the bundled starter pack via repeated
API calls keeps getting tarpitted. The puzzle DB is CC0 and contains
millions of puzzles; we just sample 25 per category from it offline.

Output shape matches `LichessPuzzle.PuzzleInfo` (the shape the in-app
JSON decoder expects):
    {
      "id":          str,
      "fen":         str,    # POSITION WHERE SOLVER IS TO MOVE
      "solution":    [str],  # UCI moves starting from the solver
      "themes":      [str],
      "rating":      int,
      "plays":       int,
      "lastMove":    str,    # opponent's set-up move that reached `fen`
      "initialPly":  null
    }

CSV column order (per Lichess docs):
  PuzzleId, FEN, Moves, Rating, RatingDeviation, Popularity,
  NbPlays, Themes, GameUrl, OpeningTags

NB: the CSV's FEN is one ply BEFORE the puzzle position — the first
move in `Moves` is the opponent's set-up move. We push that move
through python-chess to land on the solver-to-move FEN, then strip
that first move from the solution list. That matches the in-app
contract (`PuzzleSession` sets `humanSide = start.sideToMove`).

Usage:
    python3 scripts/generate_starter_puzzles_from_db.py
"""
import csv
import json
import os
import random
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

try:
    import chess
except ImportError:
    sys.stderr.write(
        "[gen] missing dep: pip3 install chess\n"
        "      (or: python3 -m pip install --user chess)\n"
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "LiveChess" / "Resources" / "puzzles_starter.json"
CACHE_ZST = ROOT / ".puzzle_cache" / "lichess_db_puzzle.csv.zst"
CACHE_CSV = ROOT / ".puzzle_cache" / "lichess_db_puzzle.csv"
DB_URL = "https://database.lichess.org/lichess_db_puzzle.csv.zst"

# Display name -> theme key, mirroring PuzzleCategory.swift in the app.
# Order matters: a puzzle is bucketed into the FIRST category it matches.
CATEGORY_THEME_MATCHERS = [
    ("mateIn1",          {"mateIn1"}),
    ("mateIn2",          {"mateIn2"}),
    # Lichess uses mateIn3/4/5 for longer forced mates — bundle them
    # together under "mateIn3" to match PuzzleCategory.mateIn3 ("Mate in 3+").
    ("mateIn3",          {"mateIn3", "mateIn4", "mateIn5"}),
    ("endgame",          {"endgame"}),
    ("middlegame",       {"middlegame"}),
    ("opening",          {"opening"}),
    ("fork",             {"fork"}),
    ("pin",              {"pin"}),
    ("skewer",           {"skewer"}),
    ("discoveredAttack", {"discoveredAttack"}),
    ("master",           {"master"}),
]
PER_CATEGORY = 25
# Filter window so the starter pack isn't dominated by trivially easy
# or master-only puzzles. Wide enough to fill all 11 categories.
RATING_MIN = 800
RATING_MAX = 2400


def download_if_missing() -> None:
    CACHE_ZST.parent.mkdir(parents=True, exist_ok=True)
    if CACHE_ZST.exists():
        print(f"[gen] cached: {CACHE_ZST} ({CACHE_ZST.stat().st_size / 1e6:.1f} MB)")
        return
    print(f"[gen] downloading {DB_URL} → {CACHE_ZST}")
    with urllib.request.urlopen(DB_URL) as resp, CACHE_ZST.open("wb") as out:
        shutil.copyfileobj(resp, out)
    print(f"[gen] downloaded {CACHE_ZST.stat().st_size / 1e6:.1f} MB")


def decompress_if_missing() -> None:
    if CACHE_CSV.exists():
        print(f"[gen] cached: {CACHE_CSV} ({CACHE_CSV.stat().st_size / 1e9:.2f} GB)")
        return
    print("[gen] decompressing with zstd…")
    subprocess.run(
        ["zstd", "-d", "-k", "-f", str(CACHE_ZST), "-o", str(CACHE_CSV)],
        check=True,
    )
    print(f"[gen] decompressed → {CACHE_CSV.stat().st_size / 1e9:.2f} GB")


def matching_categories(themes: set[str]) -> list[str]:
    """All category keys this puzzle qualifies for, in declaration order."""
    return [cat for cat, matchers in CATEGORY_THEME_MATCHERS if themes & matchers]


def pick_target(matches: list[str], buckets: dict[str, list[dict]]) -> str | None:
    """Returns the LEAST-filled matching bucket that still has room.
    Balancing across all qualifying categories instead of priority-
    order keeps the tactic rows (fork/pin/skewer/discoveredAttack)
    and master from starving, since virtually every puzzle is also
    tagged with one of mateIn*/endgame/middlegame/opening which would
    otherwise eat every row first."""
    eligible = [c for c in matches if len(buckets[c]) < PER_CATEGORY]
    if not eligible:
        return None
    return min(eligible, key=lambda c: len(buckets[c]))


def sample_csv() -> list[dict]:
    buckets: dict[str, list[dict]] = {c: [] for c, _ in CATEGORY_THEME_MATCHERS}
    all_full = lambda: all(len(buckets[c]) >= PER_CATEGORY for c, _ in CATEGORY_THEME_MATCHERS)

    print(f"[gen] scanning {CACHE_CSV.name}…")
    # Streaming: don't load 3 GB into memory. We linearly scan and stop
    # once every bucket is full. To avoid bias toward the start of the
    # file, sample with reservoir-style skipping: read in chunks and
    # shuffle each chunk before processing.
    CHUNK = 50_000
    seen = 0
    with CACHE_CSV.open(newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader, None)  # discard
        chunk: list[list[str]] = []
        for row in reader:
            chunk.append(row)
            if len(chunk) >= CHUNK:
                random.shuffle(chunk)
                for r in chunk:
                    seen += 1
                    if process_row(r, buckets):
                        if all_full():
                            print(f"[gen] all buckets full after {seen} rows")
                            return flatten(buckets)
                chunk.clear()
        # Tail
        random.shuffle(chunk)
        for r in chunk:
            seen += 1
            if process_row(r, buckets):
                if all_full():
                    print(f"[gen] all buckets full after {seen} rows")
                    return flatten(buckets)

    print(f"[gen] CSV exhausted after {seen} rows")
    for c, _ in CATEGORY_THEME_MATCHERS:
        print(f"[gen]   {c}: {len(buckets[c])}/{PER_CATEGORY}")
    return flatten(buckets)


def process_row(row: list[str], buckets: dict[str, list[dict]]) -> bool:
    """Returns True if the row was banked into a bucket."""
    if len(row) < 8:
        return False
    pid, fen, moves_s, rating_s, rd_s, _pop, plays_s, themes_s = row[:8]
    try:
        rating = int(rating_s)
    except (TypeError, ValueError):
        return False
    # RatingDeviation is the per-puzzle Glicko-2 RD. Lichess uses it
    # as the opponent RD in the user's rating update (each puzzle's
    # RD differs based on how many people have played it).
    try:
        rating_deviation = int(rd_s)
    except (TypeError, ValueError):
        rating_deviation = None
    if not (RATING_MIN <= rating <= RATING_MAX):
        return False
    themes = set(themes_s.split())
    matches = matching_categories(themes)
    cat = pick_target(matches, buckets)
    if cat is None:
        return False
    moves = moves_s.split()
    if len(moves) < 2:
        return False
    # Apply opponent's set-up move so FEN is solver-to-move (matches
    # the API shape PuzzleSession expects).
    try:
        board = chess.Board(fen)
        opponent_move = chess.Move.from_uci(moves[0])
        if opponent_move not in board.legal_moves:
            return False
        board.push(opponent_move)
        solver_fen = board.fen()
    except (ValueError, AssertionError):
        return False
    try:
        plays = int(plays_s)
    except (TypeError, ValueError):
        plays = None
    buckets[cat].append({
        "id":              pid,
        "fen":             solver_fen,
        "solution":        moves[1:],
        "themes":          sorted(themes),
        "rating":          rating,
        "ratingDeviation": rating_deviation,
        "plays":           plays,
        "lastMove":        moves[0],
        "initialPly":      None,
    })
    return True


def flatten(buckets: dict[str, list[dict]]) -> list[dict]:
    out: list[dict] = []
    for cat, _ in CATEGORY_THEME_MATCHERS:
        out.extend(buckets[cat])
    return out


def main() -> None:
    random.seed()  # different sample each run
    download_if_missing()
    decompress_if_missing()
    puzzles = sample_csv()
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(puzzles, indent=2))
    print(f"[gen] wrote {len(puzzles)} puzzles → {OUT_JSON}")


if __name__ == "__main__":
    main()
