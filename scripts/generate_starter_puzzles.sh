#!/bin/bash
# Generate LiveChess/Resources/puzzles_starter.json by fetching ~20 puzzles
# per category from Lichess. Anonymous calls (puzzle:read scope is not
# required for /api/puzzle/next). Rate-limit safe: 2-second sleep between
# requests => ~8 minutes total.
#
# Dependencies: curl, jq
# Run once on a dev machine after a network connection is available:
#     ./scripts/generate_starter_puzzles.sh

set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/LiveChess/Resources/puzzles_starter.json"
PER_CATEGORY=20
SLEEP_SECS=2

# theme keys passed as ?angle=<value> to /api/puzzle/next
CATEGORIES=(
  "mateIn1"
  "mateIn2"
  "mateIn3"
  "endgame"
  "middlegame"
  "opening"
  "fork"
  "pin"
  "skewer"
  "discoveredAttack"
  "master"
)

TMP="$(mktemp)"
echo "[]" > "$TMP"

total=0
for cat in "${CATEGORIES[@]}"; do
  echo "[gen] category: $cat"
  # Track IDs already pulled for this category so dupes don't waste API quota.
  seen=""
  fetched=0
  attempts=0
  while [ "$fetched" -lt "$PER_CATEGORY" ] && [ "$attempts" -lt $((PER_CATEGORY * 3)) ]; do
    attempts=$((attempts + 1))
    resp=$(curl -fsS "https://lichess.org/api/puzzle/next?angle=$cat" || echo "")
    if [ -z "$resp" ]; then
      echo "[gen]   (empty response, retrying)"
      sleep "$SLEEP_SECS"
      continue
    fi
    id=$(echo "$resp" | jq -r '.puzzle.id // empty')
    if [ -z "$id" ]; then
      echo "[gen]   (no id in payload, skipping)"
      sleep "$SLEEP_SECS"
      continue
    fi
    if echo " $seen " | grep -q " $id "; then
      sleep "$SLEEP_SECS"
      continue
    fi
    seen="$seen $id"
    # Append .puzzle (the PuzzleInfo block) to the running array.
    jq --argjson p "$(echo "$resp" | jq '.puzzle')" '. + [$p]' "$TMP" > "$TMP.next"
    mv "$TMP.next" "$TMP"
    fetched=$((fetched + 1))
    total=$((total + 1))
    echo "[gen]   +$id  ($fetched/$PER_CATEGORY for $cat, $total overall)"
    sleep "$SLEEP_SECS"
  done
done

echo "[gen] writing $total puzzles to $OUT"
mkdir -p "$(dirname "$OUT")"
# Pretty-print final JSON.
jq '.' "$TMP" > "$OUT"
rm -f "$TMP"
echo "[gen] done."
