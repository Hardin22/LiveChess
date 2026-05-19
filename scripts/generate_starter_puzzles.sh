#!/bin/bash
# Generate LiveChess/Resources/puzzles_starter.json by fetching ~20 puzzles
# per category from Lichess. Anonymous calls (puzzle:read scope is not
# required for /api/puzzle/next).
#
# Robustness:
#   - 5s sleep between requests to stay well under anon rate limits.
#   - HTTP 429 → exponential backoff (30s, 60s, 120s, 240s capped),
#     does NOT count toward the per-category attempts budget.
#   - Incremental save: writes OUT after every successful fetch, so a
#     killed run keeps everything banked so far.
#   - Resume: pre-existing OUT is loaded; IDs already in it are skipped.
#
# Dependencies: curl, jq
# Run on a dev machine:
#     ./scripts/generate_starter_puzzles.sh

set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/LiveChess/Resources/puzzles_starter.json"
PER_CATEGORY=20
SLEEP_SECS=8
MAX_429_BACKOFF=300

# Backoff lives on disk so it persists across the $(fetch_one ...)
# subshell — bash function variables don't propagate back from a
# command substitution.
BACKOFF_FILE="$(mktemp -t lichess_backoff.XXXXXX)"
echo 30 > "$BACKOFF_FILE"
trap 'rm -f "$BACKOFF_FILE"' EXIT

CATEGORIES=(
  "mateIn1" "mateIn2" "mateIn3" "endgame" "middlegame" "opening"
  "fork" "pin" "skewer" "discoveredAttack" "master"
)

mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo "[]" > "$OUT"

# Seed `seen_global` from anything already on disk so a resumed run
# doesn't burn fetches on puzzles it already has.
seen_global=" $(jq -r '.[].id' "$OUT" | tr '\n' ' ') "
existing_count=$(jq 'length' "$OUT")
echo "[gen] resuming with $existing_count puzzle(s) already on disk"

append_puzzle_to_out() {
  local payload="$1"  # JSON object: the .puzzle block
  local id
  id=$(echo "$payload" | jq -r '.id')
  jq --argjson p "$payload" '. + [$p]' "$OUT" > "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
  seen_global="$seen_global$id "
}

# fetch_one <angle> → echoes the JSON puzzle payload on success, or
# empty string on dupe / no-id (caller retries). Sleeps SLEEP_SECS on
# success, exponential backoff on 429.
fetch_one() {
  local angle="$1"
  local body http
  local tmp; tmp=$(mktemp)
  local backoff
  backoff=$(cat "$BACKOFF_FILE")
  http=$(curl -s -o "$tmp" -w "%{http_code}" \
              "https://lichess.org/api/puzzle/next?angle=$angle" || echo "000")
  if [ "$http" = "429" ]; then
    echo "[gen]   HTTP 429 (rate-limited) — sleeping ${backoff}s..." >&2
    sleep "$backoff"
    if [ "$backoff" -lt "$MAX_429_BACKOFF" ]; then
      backoff=$((backoff * 2))
      [ "$backoff" -gt "$MAX_429_BACKOFF" ] && backoff=$MAX_429_BACKOFF
      echo "$backoff" > "$BACKOFF_FILE"
    fi
    rm -f "$tmp"
    return 2   # 429 — retry without burning budget
  fi
  # Successful HTTP — reset backoff on disk.
  echo 30 > "$BACKOFF_FILE"
  if [ "$http" != "200" ]; then
    echo "[gen]   HTTP $http (non-200) — skip and retry" >&2
    rm -f "$tmp"
    sleep "$SLEEP_SECS"
    return 1
  fi
  body=$(cat "$tmp"); rm -f "$tmp"
  local id; id=$(echo "$body" | jq -r '.puzzle.id // empty')
  if [ -z "$id" ]; then
    sleep "$SLEEP_SECS"
    return 1
  fi
  if echo "$seen_global" | grep -q " $id "; then
    sleep "$SLEEP_SECS"
    return 1
  fi
  echo "$body" | jq '.puzzle'
  sleep "$SLEEP_SECS"
  return 0
}

total=$existing_count
for cat in "${CATEGORIES[@]}"; do
  # Count puzzles this category already has (could be non-zero from a
  # prior resumed run). Threshold against PER_CATEGORY so a partially
  # done category resumes instead of restarting.
  have=$(jq --arg t "$cat" '[.[] | select(.themes | index($t))] | length' "$OUT")
  echo "[gen] category: $cat (already have $have)"
  attempts=0
  while [ "$have" -lt "$PER_CATEGORY" ] && [ "$attempts" -lt $((PER_CATEGORY * 4)) ]; do
    attempts=$((attempts + 1))
    if payload=$(fetch_one "$cat"); then
      append_puzzle_to_out "$payload"
      have=$((have + 1))
      total=$((total + 1))
      id=$(echo "$payload" | jq -r '.id')
      echo "[gen]   +$id  ($have/$PER_CATEGORY for $cat, $total overall)"
    fi
    # rc=2 (429) loops without incrementing `attempts` due to the
    # backoff sleep already eaten inside fetch_one; rc=1 (dupe/no-id)
    # counts as an attempt.
  done
done

echo "[gen] writing $total puzzles to $OUT"
# Final pretty-print pass (in-place via tmp file).
jq '.' "$OUT" > "$OUT.final"
mv "$OUT.final" "$OUT"
echo "[gen] done."
