#!/usr/bin/env bash
# scripts/score_module.sh
# Big Rock 2: Score any module + entity combination
# Source: DATA-1 delivery (to_STRAT_DEV_from_DATA-1_20260201T0120Z)
#
# Usage: ./scripts/score_module.sh <module> <entity_id>
#
# Examples:
#   ./scripts/score_module.sh attribution cll_06DSX0CVZHZK72VCVW54EH9G3C
#   ./scripts/score_module.sh project 7db5e186-7dda-4c2c-b85e-7235b67e06d8

print_help() {
  cat <<'EOF'
Usage: ./scripts/score_module.sh <module> <entity_id> [--help|-h]

Score any module/entity combination via Supabase RPC.
Examples:
  ./scripts/score_module.sh attribution cll_06DSX0CVZHZK72VCVW54EH9G3C
  ./scripts/score_module.sh project 7db5e186-7dda-4c2c-b85e-7235b67e06d8
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

if [[ $# -lt 2 ]]; then
  print_help >&2
  exit 2
fi

set -euo pipefail

# Load credentials from canonical source
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR/..")"

# Try central credential loader first
if [[ -f "$HOME/.camber/load-credentials.sh" ]]; then
  source "$HOME/.camber/load-credentials.sh" 2>/dev/null || true
fi

# Fallback to local load-env.sh
if [[ -z "${SUPABASE_URL:-}" ]] && [[ -f "$REPO_ROOT/scripts/load-env.sh" ]]; then
  source "$REPO_ROOT/scripts/load-env.sh"
fi

# Verify required env vars
for var in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Missing required env var: $var" >&2
    echo "Run: source ~/.camber/load-credentials.sh" >&2
    exit 2
  fi
done

MODULE="$1"
ENTITY_ID="$2"

# Route to appropriate RPC based on module
case "$MODULE" in
  attribution)
    RPC_NAME="score_attribution"
    PAYLOAD="{\"p_interaction_id\": \"$ENTITY_ID\"}"
    ;;
  project)
    RPC_NAME="score_project"
    PAYLOAD="{\"p_project_id\": \"$ENTITY_ID\"}"
    ;;
  *)
    RPC_NAME="score_module"
    PAYLOAD="{\"p_module\": \"$MODULE\", \"p_entity_id\": \"$ENTITY_ID\"}"
    ;;
esac

# Execute RPC
RESULT=$(curl -s "${SUPABASE_URL}/rest/v1/rpc/${RPC_NAME}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

# Check for errors
if echo "$RESULT" | jq -e '.code' >/dev/null 2>&1; then
  ERROR=$(echo "$RESULT" | jq -r '.message // "Unknown error"')
  echo "ERROR | $MODULE | $ENTITY_ID | $ERROR" >&2
  exit 1
fi

# Parse result (handle both array and object responses)
if echo "$RESULT" | jq -e '.[0]' >/dev/null 2>&1; then
  ROW=$(echo "$RESULT" | jq '.[0]')
else
  ROW="$RESULT"
fi

# Extract fields with defaults
STATUS=$(echo "$ROW" | jq -r '.status // "UNKNOWN"')
CLAIMS=$(echo "$ROW" | jq -r '.claims_count // .total_attributions // 0')
REVIEW=$(echo "$ROW" | jq -r '.open_review_count // 0')
UNCOVERED=$(echo "$ROW" | jq -r '.uncovered_count // 0')
DOUBLE=$(echo "$ROW" | jq -r '.double_covered_count // 0')
LAST=$(echo "$ROW" | jq -r '.last_claim_at // .last_attribution_at // "never"')

# Print one-line result
echo "$STATUS | $MODULE | $ENTITY_ID | claims=$CLAIMS review=$REVIEW uncovered=$UNCOVERED double=$DOUBLE | last=$LAST"

# Exit code based on status
case "$STATUS" in
  PASS)
    exit 0
    ;;
  PENDING_REVIEW)
    # Pending review is expected, not a failure
    exit 0
    ;;
  FAIL_UNCOVERED|WARN_UNCOVERED|WARN_BACKLOG)
    exit 1
    ;;
  NO_DATA)
    echo "WARNING: No data found for $MODULE:$ENTITY_ID" >&2
    exit 0
    ;;
  *)
    echo "WARNING: Unknown status '$STATUS'" >&2
    exit 1
    ;;
esac
