#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# redline_assistant_harness.sh — CLI harness for the redline-assistant Edge Fn
#
# Usage:
#   scripts/redline_assistant_harness.sh "What projects do you have?"
#   scripts/redline_assistant_harness.sh "What's going on with Winship?"
#   scripts/redline_assistant_harness.sh --project-id <uuid> "status update"
#   scripts/redline_assistant_harness.sh --contact-id <uuid> "next steps"
#   scripts/redline_assistant_harness.sh --raw "What projects do you have?"
#
# Env vars (auto-sourced from ~/.camber/credentials.env if present):
#   SUPABASE_URL          — project URL
#   SUPABASE_SERVICE_ROLE_KEY — service role key (used as Bearer + apikey)
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  redline_assistant_harness.sh [OPTIONS] "<message>"

Options:
  --project-id <uuid>   Scope to a specific project
  --contact-id <uuid>   Scope to a specific contact
  --model <model_id>    Override LLM model (default: server-side config)
  --raw                 Print raw SSE stream instead of extracted text
  --headers             Print response headers
  -h, --help            Show this help

Examples:
  scripts/redline_assistant_harness.sh "What projects do you have?"
  scripts/redline_assistant_harness.sh "Tell me about Winship"
  scripts/redline_assistant_harness.sh --project-id 310a3768-d7c0-4e72-88d0-aa67bf4d1b05 "status"
  scripts/redline_assistant_harness.sh --raw --headers "What's happening today?"
EOF
}

# Source credentials if available
if [[ -f "${HOME}/.camber/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.camber/credentials.env"
fi

PROJECT_ID=""
CONTACT_ID=""
MODEL=""
RAW=false
SHOW_HEADERS=false
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)  PROJECT_ID="${2:-}"; shift 2 ;;
    --contact-id)  CONTACT_ID="${2:-}"; shift 2 ;;
    --model)       MODEL="${2:-}"; shift 2 ;;
    --raw)         RAW=true; shift ;;
    --headers)     SHOW_HEADERS=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)             MESSAGE="$1"; shift ;;
  esac
done

if [[ -z "$MESSAGE" ]]; then
  echo "[ERROR] Message argument is required." >&2
  usage >&2
  exit 1
fi

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "[ERROR] SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set." >&2
  echo "        Source ~/.camber/credentials.env or export them." >&2
  exit 1
fi

ENDPOINT="${SUPABASE_URL}/functions/v1/redline-assistant"
REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "harness-$(date +%s)")"

# Build JSON body
BODY=$(jq -cn \
  --arg message "$MESSAGE" \
  --arg project_id "$PROJECT_ID" \
  --arg contact_id "$CONTACT_ID" \
  --arg model "$MODEL" \
  '{message: $message}
   + (if $project_id != "" then {project_id: $project_id} else {} end)
   + (if $contact_id != "" then {contact_id: $contact_id} else {} end)
   + (if $model != "" then {model: $model} else {} end)')

echo "--- redline-assistant harness ---"
echo "  endpoint:   ${ENDPOINT}"
echo "  request_id: ${REQUEST_ID}"
echo "  body:       ${BODY}"
echo "---"
echo

HEADER_FILE="$(mktemp)"
trap 'rm -f "$HEADER_FILE"' EXIT

if $RAW; then
  curl -sS \
    -X POST "${ENDPOINT}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "x-request-id: ${REQUEST_ID}" \
    -D "$HEADER_FILE" \
    -d "${BODY}"
else
  # Stream and extract text content from SSE chunks
  curl -sS \
    -X POST "${ENDPOINT}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "x-request-id: ${REQUEST_ID}" \
    -D "$HEADER_FILE" \
    -d "${BODY}" \
  | while IFS= read -r line; do
      # Strip "data: " prefix
      data="${line#data: }"
      if [[ "$data" == "[DONE]" ]]; then
        break
      fi
      if [[ -n "$data" && "$data" != "$line" ]]; then
        # Extract .choices[0].delta.content from the JSON
        content="$(echo "$data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null || true)"
        if [[ -n "$content" ]]; then
          printf "%s" "$content"
        fi
      fi
    done
  echo  # final newline
fi

echo
if $SHOW_HEADERS; then
  echo "--- Response Headers ---"
  cat "$HEADER_FILE"
  echo "---"
else
  # Always show contract headers
  echo "--- Contract Headers ---"
  grep -iE "^x-(request-id|function-version|contract-version|model-id|model-config-source):" "$HEADER_FILE" 2>/dev/null || echo "(none found)"
  echo "---"
fi
