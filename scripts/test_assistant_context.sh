#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test_assistant_context.sh — CLI harness for the assistant-context Edge Fn
#
# Queries the assistant-context Edge Function and reports whether Winship
# (or any named project) appears in top_projects, with full data dump.
#
# Usage:
#   scripts/test_assistant_context.sh
#   scripts/test_assistant_context.sh --project winship
#   scripts/test_assistant_context.sh --project-id <uuid>
#   scripts/test_assistant_context.sh --limit 20
#   scripts/test_assistant_context.sh --raw
#
# Env vars (auto-sourced from ~/.camber/credentials.env if present):
#   SUPABASE_URL               — project URL
#   SUPABASE_SERVICE_ROLE_KEY  — service role key (used as Bearer + apikey)
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  test_assistant_context.sh [OPTIONS]

Options:
  --project <name>    Search for project by name (case-insensitive, default: winship)
  --project-id <uuid> Fetch project-specific context for this UUID
  --limit <n>         Max top_projects to fetch (default: 20)
  --raw               Print full raw JSON response
  --headers           Print response headers
  -h, --help          Show this help

Examples:
  scripts/test_assistant_context.sh
  scripts/test_assistant_context.sh --project "Moss Residence"
  scripts/test_assistant_context.sh --project-id 310a3768-d7c0-4e72-88d0-aa67bf4d1b05
  scripts/test_assistant_context.sh --raw --limit 50
EOF
}

# Source credentials if available
if [[ -f "${HOME}/.camber/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.camber/credentials.env"
fi

PROJECT_NAME="winship"
PROJECT_ID=""
LIMIT=20
RAW=false
SHOW_HEADERS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)     PROJECT_NAME="${2:-}"; shift 2 ;;
    --project-id)  PROJECT_ID="${2:-}"; shift 2 ;;
    --limit)       LIMIT="${2:-20}"; shift 2 ;;
    --raw)         RAW=true; shift ;;
    --headers)     SHOW_HEADERS=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)             echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "[ERROR] SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set." >&2
  echo "        Source ~/.camber/credentials.env or export them." >&2
  exit 1
fi

for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[ERROR] ${bin} is required but not found." >&2
    exit 1
  fi
done

ENDPOINT="${SUPABASE_URL}/functions/v1/assistant-context"
REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "test-ctx-$(date +%s)")"
HEADER_FILE="$(mktemp)"
trap 'rm -f "$HEADER_FILE"' EXIT

# ============================================================================
# STEP 1: Fetch the global assistant-context packet
# ============================================================================

echo "=== assistant-context harness ==="
echo "  endpoint:   ${ENDPOINT}"
echo "  request_id: ${REQUEST_ID}"
echo "  limit:      ${LIMIT}"
echo "  project:    ${PROJECT_NAME}"
echo "==="
echo

URL="${ENDPOINT}?limit=${LIMIT}"

RESPONSE=$(curl -sS \
  -X GET "${URL}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-request-id: ${REQUEST_ID}" \
  -D "$HEADER_FILE" \
  -w '\n')

# Check for valid JSON
if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
  echo "[ERROR] Non-JSON response from assistant-context:"
  echo "$RESPONSE"
  exit 1
fi

OK=$(echo "$RESPONSE" | jq -r '.ok // false')
if [[ "$OK" != "true" ]]; then
  echo "[ERROR] assistant-context returned ok=false"
  echo "$RESPONSE" | jq '.'
  exit 1
fi

if $RAW; then
  echo "$RESPONSE" | jq '.'
  exit 0
fi

# ============================================================================
# Contract metadata
# ============================================================================

echo "--- Contract Metadata ---"
echo "$RESPONSE" | jq '{
  request_id,
  function_version,
  contract_version,
  generated_at,
  ms
}'

if $SHOW_HEADERS; then
  echo
  echo "--- Response Headers ---"
  cat "$HEADER_FILE"
fi

# ============================================================================
# STEP 2: Top projects summary
# ============================================================================

TOP_COUNT=$(echo "$RESPONSE" | jq '.top_projects | length')
echo
echo "--- Top Projects (${TOP_COUNT} returned) ---"
echo "$RESPONSE" | jq -r '
  .top_projects[] |
  "  \(.project_name // "?")  |  7d: calls=\(.interactions_7d // 0) claims=\(.active_journal_claims_7d // 0) loops=\(.open_loops_7d // 0) reviews=\(.pending_reviews_queue_7d // 0)  |  risk=\(.risk_flag // "none")"
'

# ============================================================================
# STEP 3: Search for target project in top_projects
# ============================================================================

SEARCH_LOWER=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')
MATCH=$(echo "$RESPONSE" | jq --arg name "$SEARCH_LOWER" '
  [.top_projects[] | select(.project_name | ascii_downcase | contains($name))]
')
MATCH_COUNT=$(echo "$MATCH" | jq 'length')

echo
echo "=== Winship / \"${PROJECT_NAME}\" Search ==="
if [[ "$MATCH_COUNT" -gt 0 ]]; then
  echo "FOUND: ${MATCH_COUNT} match(es) in top_projects"
  echo "$MATCH" | jq -r '.[] | "  project_id: \(.project_id)\n  project_name: \(.project_name)\n  phase: \(.phase // "null")\n  interactions_7d: \(.interactions_7d // 0)\n  active_journal_claims_total: \(.active_journal_claims_total // 0)\n  active_journal_claims_7d: \(.active_journal_claims_7d // 0)\n  open_loops_total: \(.open_loops_total // 0)\n  open_loops_7d: \(.open_loops_7d // 0)\n  pending_reviews_span_total: \(.pending_reviews_span_total // 0)\n  pending_reviews_queue_total: \(.pending_reviews_queue_total // 0)\n  pending_reviews_queue_7d: \(.pending_reviews_queue_7d // 0)\n  striking_signal_count: \(.striking_signal_count // 0)\n  risk_flag: \(.risk_flag // "none")\n  ---"'

  # Use first match's project_id for deep context if no --project-id given
  if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID=$(echo "$MATCH" | jq -r '.[0].project_id')
    echo "  (auto-selected project_id=${PROJECT_ID} for deep context)"
  fi
else
  echo "NOT FOUND in top_projects."
  echo
  echo "Diagnostic: listing all project names returned:"
  echo "$RESPONSE" | jq -r '.top_projects[].project_name // "null"' | sort | sed 's/^/  /'
fi

# ============================================================================
# STEP 4: Who-needs-you signals for target project
# ============================================================================

WHO_MATCH=$(echo "$RESPONSE" | jq --arg name "$SEARCH_LOWER" '
  [.who_needs_you // [] | .[] | select(.project | ascii_downcase | contains($name))]
')
WHO_COUNT=$(echo "$WHO_MATCH" | jq 'length')

echo
echo "--- Who Needs You signals for \"${PROJECT_NAME}\" ---"
if [[ "$WHO_COUNT" -gt 0 ]]; then
  echo "FOUND: ${WHO_COUNT} signal(s)"
  echo "$WHO_MATCH" | jq -r '.[] | "  [\(.category)] \(.detail) (speaker=\(.speaker // "?"), \(.hours_ago)h ago)"'
else
  echo "No who_needs_you signals for \"${PROJECT_NAME}\"."
fi

# ============================================================================
# STEP 5: Review pressure for target project
# ============================================================================

REVIEW_MATCH=$(echo "$RESPONSE" | jq --arg name "$SEARCH_LOWER" '
  [.review_pressure_by_project // [] | .[] | select(.project_name | ascii_downcase | contains($name))]
')
REVIEW_COUNT=$(echo "$REVIEW_MATCH" | jq 'length')

echo
echo "--- Review Pressure for \"${PROJECT_NAME}\" ---"
if [[ "$REVIEW_COUNT" -gt 0 ]]; then
  echo "FOUND: ${REVIEW_COUNT} entry/entries"
  echo "$REVIEW_MATCH" | jq '.'
else
  echo "No review_pressure_by_project entries for \"${PROJECT_NAME}\"."
fi

# ============================================================================
# STEP 6: Deep project context (if project_id available)
# ============================================================================

if [[ -n "$PROJECT_ID" ]]; then
  echo
  echo "=== Deep Project Context (project_id=${PROJECT_ID}) ==="
  DEEP_REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "test-ctx-deep-$(date +%s)")"
  DEEP_URL="${ENDPOINT}?limit=${LIMIT}&project_id=${PROJECT_ID}"

  DEEP_RESPONSE=$(curl -sS \
    -X GET "${DEEP_URL}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "x-request-id: ${DEEP_REQUEST_ID}" \
    -w '\n')

  DEEP_OK=$(echo "$DEEP_RESPONSE" | jq -r '.ok // false' 2>/dev/null)
  if [[ "$DEEP_OK" == "true" ]]; then
    PC=$(echo "$DEEP_RESPONSE" | jq '.project_context')
    if [[ "$PC" != "null" ]]; then
      echo
      echo "--- Project Summary ---"
      echo "$PC" | jq '.project'

      TIMELINE_COUNT=$(echo "$PC" | jq '.recent_timeline | length')
      echo
      echo "--- Recent Timeline (${TIMELINE_COUNT} events) ---"
      echo "$PC" | jq -r '
        .recent_timeline[:5][] |
        "  [\(.event_type // "?")] \(.event_at // "?") — \(.summary // "(no summary)") [contact=\(.contact_name // "?")]"
      '
      if [[ "$TIMELINE_COUNT" -gt 5 ]]; then
        echo "  ... and $((TIMELINE_COUNT - 5)) more"
      fi

      echo
      echo "--- Intelligence Coverage ---"
      echo "$PC" | jq '.intelligence'
    else
      echo "project_context is null (project may not exist or has no data)."
    fi
  else
    echo "[ERROR] Deep context request failed:"
    echo "$DEEP_RESPONSE" | jq '.' 2>/dev/null || echo "$DEEP_RESPONSE"
  fi
fi

# ============================================================================
# STEP 7: Pipeline health snapshot
# ============================================================================

echo
echo "--- Pipeline Health ---"
echo "$RESPONSE" | jq -r '
  .pipeline_health // [] | .[] |
  "  \(.capability): \(.total // 0) rows, \(.hours_stale // "?")h stale"
'

# ============================================================================
# Summary verdict
# ============================================================================

echo
echo "========================================="
if [[ "$MATCH_COUNT" -gt 0 ]]; then
  echo "VERDICT: \"${PROJECT_NAME}\" IS present in assistant-context."
  echo "  The data-grounding path should work for this project."
  echo "  If redline-assistant still says 'no info', the bug is in"
  echo "  the LLM prompt assembly or model interpretation, not data."
else
  echo "VERDICT: \"${PROJECT_NAME}\" is NOT in assistant-context top_projects."
  echo "  Possible causes:"
  echo "  1. Project not in projects table"
  echo "  2. No interactions in last 7 days (interactions_7d = 0)"
  echo "  3. Limit too low (try --limit 50)"
  echo "  4. Project name mismatch (check exact spelling)"
fi
echo "========================================="
