#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$ROOT/Tests/Fixtures/shopping_query_cases.json"
OUTPUT="$ROOT/.evaluation/planner-v1"
PROMPT_ID="planner-v1"
RUNS=5
LIMIT=""
CASE_IDS=()
CASE_IDS_COUNT=0
NO_RESUME=0
REQUIRE_MODEL=1

usage() {
  cat <<'EOF'
Usage: Scripts/evaluate_queries.sh [options]

  --prompt-id ID   Label recorded in observations (default: planner-v1)
  --runs N         Generations per case (default: 5)
  --output DIR     Evaluation directory (default: .evaluation/<prompt-id>)
  --cases PATH     Query corpus path
  --case ID        Evaluate one case; repeatable
  --limit N        Evaluate only the first N selected cases
  --no-resume      Replace an existing observation file
  --allow-fallback Score rule-based degradation instead of failing collection
  -h, --help       Show this help
EOF
}

while (($#)); do
  case "$1" in
    --prompt-id) PROMPT_ID="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --case) CASE_IDS+=("$2"); CASE_IDS_COUNT=$((CASE_IDS_COUNT + 1)); shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --no-resume) NO_RESUME=1; shift ;;
    --allow-fallback) REQUIRE_MODEL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$OUTPUT" == "$ROOT/.evaluation/planner-v1" && "$PROMPT_ID" != "planner-v1" ]]; then
  OUTPUT="$ROOT/.evaluation/$PROMPT_ID"
fi

if [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
fi

mkdir -p "$OUTPUT"

COLLECT=(swift run --package-path "$ROOT" crumb-query-collect
  --cases "$CASES" --output "$OUTPUT" --prompt-id "$PROMPT_ID" --runs "$RUNS")
if ((CASE_IDS_COUNT)); then
  for id in "${CASE_IDS[@]}"; do COLLECT+=(--case "$id"); done
fi
if [[ -n "$LIMIT" ]]; then COLLECT+=(--limit "$LIMIT"); fi
if ((NO_RESUME)); then COLLECT+=(--no-resume); fi
if ((REQUIRE_MODEL)); then COLLECT+=(--require-model); fi

"${COLLECT[@]}"

SCORE=(swift run --package-path "$ROOT" crumb-query-harness
  --cases "$CASES" --observations "$OUTPUT/observations.json")
if [[ -n "$LIMIT" ]] || ((CASE_IDS_COUNT)); then SCORE+=(--allow-partial); fi

"${SCORE[@]}" --format text | tee "$OUTPUT/report.txt"
"${SCORE[@]}" --format json > "$OUTPUT/report.json"

echo "Evaluation artifacts: $OUTPUT"
