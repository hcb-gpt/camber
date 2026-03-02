#!/usr/bin/env bash
# backfill-review-span-extraction.sh
# Calls journal-extract Edge Function for review spans missing claims.
# Uses v_review_spans_missing_extraction view to identify targets.
#
# Usage: ./scripts/backfill-review-span-extraction.sh [--dry-run] [--limit N] [--delay-ms N]
#
# Prerequisites: source ~/.camber/credentials.env (needs EDGE_SHARED_SECRET, SUPABASE_SERVICE_ROLE_KEY)

set -euo pipefail

SUPABASE_URL="https://rjhdwidddtfetbwqolof.supabase.co"
FUNCTION_URL="${SUPABASE_URL}/functions/v1/journal-extract"
DRY_RUN=false
LIMIT=408
DELAY_MS=500
BATCH_SIZE=10

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --limit)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --limit requires a positive integer." >&2
        exit 2
      fi
      LIMIT="$2"
      shift 2
      ;;
    --delay-ms)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --delay-ms requires a non-negative integer." >&2
        exit 2
      fi
      DELAY_MS="$2"
      shift 2
      ;;
    --batch-size)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --batch-size requires a positive integer." >&2
        exit 2
      fi
      BATCH_SIZE="$2"
      shift 2
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ ! "${LIMIT}" =~ ^[0-9]+$ ]] || (( LIMIT <= 0 )); then
  echo "ERROR: --limit must be a positive integer." >&2
  exit 2
fi
if [[ ! "${DELAY_MS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --delay-ms must be a non-negative integer." >&2
  exit 2
fi
if [[ ! "${BATCH_SIZE}" =~ ^[0-9]+$ ]] || (( BATCH_SIZE <= 0 )); then
  echo "ERROR: --batch-size must be a positive integer." >&2
  exit 2
fi

# Validate secrets
if [[ -z "${EDGE_SHARED_SECRET:-}" ]]; then
  echo "ERROR: EDGE_SHARED_SECRET not set. Run: source ~/.camber/credentials.env"
  exit 1
fi
if [[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_SERVICE_ROLE_KEY not set. Run: source ~/.camber/credentials.env"
  exit 1
fi

echo "=== Review Span Extraction Backfill ==="
echo "DRY_RUN: ${DRY_RUN}"
echo "LIMIT: ${LIMIT}"
echo "DELAY_MS: ${DELAY_MS}"
echo "TARGET: ${FUNCTION_URL}"
echo ""

# Fetch target span_ids from the view via PostgREST
echo "Fetching target spans from v_review_spans_missing_extraction..."
SPANS_JSON=$(curl -s \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  "${SUPABASE_URL}/rest/v1/v_review_spans_missing_extraction?select=span_id,interaction_id,confidence&order=confidence.desc&limit=${LIMIT}")

# Count spans
SPAN_COUNT=$(echo "${SPANS_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "Found ${SPAN_COUNT} spans to process"
echo ""

if [[ "${SPAN_COUNT}" == "0" ]]; then
  echo "No spans to process. Exiting."
  exit 0
fi

# Process each span
SUCCESS=0
FAILED=0
SKIPPED=0
TOTAL_CLAIMS=0

echo "Starting extraction (batch delay: ${DELAY_MS}ms)..."
echo "---"

echo "${SPANS_JSON}" | python3 -c "
import sys, json
spans = json.load(sys.stdin)
for s in spans:
    print(f\"{s['span_id']}|{s['interaction_id']}|{s['confidence']}\")
" | while IFS='|' read -r SPAN_ID INTERACTION_ID CONFIDENCE; do
  # Call journal-extract
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "${FUNCTION_URL}" \
    -H "Content-Type: application/json" \
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
    -d "{\"span_id\": \"${SPAN_ID}\", \"dry_run\": ${DRY_RUN}}")

  HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
  BODY=$(echo "${RESPONSE}" | sed '$d')

  # Parse result
  OK=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ok',''))" 2>/dev/null || echo "")
  CLAIMS=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claims_extracted', d.get('existing_claims', 0)))" 2>/dev/null || echo "0")
  IDEMPOTENT=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('idempotent_skip',''))" 2>/dev/null || echo "")
  REASON=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reason',''))" 2>/dev/null || echo "")

  if [[ "${HTTP_CODE}" == "200" && "${OK}" == "True" ]]; then
    if [[ "${IDEMPOTENT}" == "True" ]]; then
      echo "SKIP ${SPAN_ID} (already extracted, ${CLAIMS} claims) conf=${CONFIDENCE}"
    else
      echo "OK   ${SPAN_ID} claims=${CLAIMS} conf=${CONFIDENCE} ${REASON}"
    fi
  else
    echo "FAIL ${SPAN_ID} http=${HTTP_CODE} conf=${CONFIDENCE}"
    echo "     ${BODY}" | head -c 200
    echo ""
  fi

  # Rate limit
  sleep "$(echo "scale=3; ${DELAY_MS}/1000" | bc)"
done

echo ""
echo "=== Backfill Complete ==="
echo "Check post-backfill counts with:"
echo "  SELECT COUNT(*) FROM v_review_spans_missing_extraction;"
echo "  SELECT COUNT(*) FROM journal_claims WHERE source_span_id IN (SELECT span_id FROM span_attributions WHERE decision='review');"
