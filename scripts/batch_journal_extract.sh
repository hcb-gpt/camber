#!/usr/bin/env bash
set -euo pipefail

# batch_journal_extract.sh
# Batch reprocess: invoke journal-extract for calls that have conversation_spans
# but no journal_claims. Processes each span individually.
#
# Created: 2026-02-14 by DEV-2
# TRAM ref: strat1_directive_dev2_batch_reprocess_script
#
# Usage:
#   # Process all eligible spans (with project attribution):
#   ./scripts/batch_journal_extract.sh
#
#   # Process a specific list of interaction_ids:
#   ./scripts/batch_journal_extract.sh --ids-file interaction_ids.txt
#
#   # Dry run (no DB writes):
#   ./scripts/batch_journal_extract.sh --dry-run
#
#   # Limit batch size:
#   ./scripts/batch_journal_extract.sh --batch-size 50
#
# Env vars (required — loaded from ~/.camber/credentials.env):
#   SUPABASE_URL
#   SUPABASE_SERVICE_ROLE_KEY
#   EDGE_SHARED_SECRET
#
# Env vars (optional):
#   BATCH_DELAY_MS   delay between span calls (default: 2000)
#   BATCH_SIZE        max spans to process (default: all)

# ── CONFIG ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPABASE_PROJECT_URL="https://rjhdwidddtfetbwqolof.supabase.co"
FUNCTION_URL="${SUPABASE_PROJECT_URL}/functions/v1/journal-extract"
LOG_DIR="/tmp/batch_journal_extract"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
LOG_FILE="${LOG_DIR}/run_${TIMESTAMP}.log"
RESULTS_FILE="${LOG_DIR}/results_${TIMESTAMP}.csv"

BATCH_DELAY_MS="${BATCH_DELAY_MS:-2000}"
BATCH_SIZE="${BATCH_SIZE:-0}"  # 0 = unlimited
DRY_RUN=false
IDS_FILE=""

# ── PARSE ARGS ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true; shift ;;
    --batch-size)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --batch-size requires a numeric value" >&2
        exit 2
      fi
      BATCH_SIZE="$2"
      shift 2
      ;;
    --ids-file)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --ids-file requires a file path" >&2
        exit 2
      fi
      IDS_FILE="$2"
      shift 2
      ;;
    --delay-ms)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --delay-ms requires a numeric value" >&2
        exit 2
      fi
      BATCH_DELAY_MS="$2"
      shift 2
      ;;
    *)             echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── LOAD CREDENTIALS ───────────────────────────────────────────────
if [ -f "$HOME/.camber/credentials.env" ]; then
  set -a
  source "$HOME/.camber/credentials.env"
  set +a
fi

for var in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY EDGE_SHARED_SECRET; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: Missing required env var: $var" >&2
    exit 1
  fi
done

# ── SETUP ──────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
echo "interaction_id,span_id,span_index,status,claims_extracted,claims_written,skipped_reason,ms" > "$RESULTS_FILE"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

log "=== Batch Journal Extract ==="
log "Function URL: $FUNCTION_URL"
log "Dry run: $DRY_RUN"
log "Batch delay: ${BATCH_DELAY_MS}ms"
log "Batch size limit: ${BATCH_SIZE:-unlimited}"
log "Log file: $LOG_FILE"
log "Results CSV: $RESULTS_FILE"

# ── GET TARGET SPANS ───────────────────────────────────────────────
# Query Supabase for spans that need processing
get_target_spans() {
  local limit_clause=""
  if [ "$BATCH_SIZE" -gt 0 ] 2>/dev/null; then
    limit_clause="LIMIT $BATCH_SIZE"
  fi

  local query
  if [ -n "$IDS_FILE" ]; then
    # Read interaction_ids from file and filter
    local ids_list=""
    while IFS= read -r line; do
      line=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$line" ] && continue
      [ -n "$ids_list" ] && ids_list="${ids_list},"
      ids_list="${ids_list}'${line}'"
    done < "$IDS_FILE"

    query="SELECT cs.interaction_id, cs.id as span_id, cs.span_index
FROM conversation_spans cs
JOIN span_attributions sa ON sa.span_id = cs.id
WHERE cs.interaction_id NOT IN (
  SELECT DISTINCT call_id FROM journal_claims WHERE call_id IS NOT NULL
)
AND cs.interaction_id IN (${ids_list})
AND cs.is_superseded = false
AND (sa.applied_project_id IS NOT NULL OR sa.project_id IS NOT NULL)
ORDER BY cs.interaction_id, cs.span_index
${limit_clause}"
  else
    query="SELECT cs.interaction_id, cs.id as span_id, cs.span_index
FROM conversation_spans cs
JOIN span_attributions sa ON sa.span_id = cs.id
WHERE cs.interaction_id NOT IN (
  SELECT DISTINCT call_id FROM journal_claims WHERE call_id IS NOT NULL
)
AND cs.interaction_id LIKE 'cll_06%'
AND cs.is_superseded = false
AND (sa.applied_project_id IS NOT NULL OR sa.project_id IS NOT NULL)
ORDER BY cs.interaction_id, cs.span_index
${limit_clause}"
  fi

  # Use Supabase REST API to run SQL via RPC
  curl -s "${SUPABASE_PROJECT_URL}/rest/v1/rpc/exec_sql" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$query" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" 2>/dev/null
}

# ── PROCESS SINGLE SPAN ───────────────────────────────────────────
process_span() {
  local interaction_id="$1"
  local span_id="$2"
  local span_index="$3"

  local payload="{\"span_id\":\"${span_id}\"}"
  if [ "$DRY_RUN" = true ]; then
    payload="{\"span_id\":\"${span_id}\",\"dry_run\":true}"
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "$FUNCTION_URL" \
    -H "Content-Type: application/json" \
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
    -d "$payload" \
    --max-time 90 2>&1) || true

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    local ok claims_extracted claims_written skipped ms reason
    ok=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ok',''))" 2>/dev/null || echo "")
    claims_extracted=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claims_extracted',0))" 2>/dev/null || echo "0")
    claims_written=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claims_written',0))" 2>/dev/null || echo "0")
    ms=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ms',0))" 2>/dev/null || echo "0")
    reason=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reason',''))" 2>/dev/null || echo "")
    local idempotent_skip
    idempotent_skip=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('idempotent_skip',False))" 2>/dev/null || echo "False")

    local status="ok"
    local skipped_reason=""
    if [ "$idempotent_skip" = "True" ]; then
      status="skipped_idempotent"
      skipped_reason="already_processed"
    elif [ -n "$reason" ]; then
      status="skipped"
      skipped_reason="$reason"
    fi

    echo "${interaction_id},${span_id},${span_index},${status},${claims_extracted},${claims_written},${skipped_reason},${ms}" >> "$RESULTS_FILE"
    log "  OK: ${interaction_id} span=${span_index} claims=${claims_written}/${claims_extracted} ${skipped_reason:+(${skipped_reason})} ${ms}ms"
  else
    local error_msg
    error_msg=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','unknown'))" 2>/dev/null || echo "http_${http_code}")
    echo "${interaction_id},${span_id},${span_index},error_${http_code},0,0,${error_msg},0" >> "$RESULTS_FILE"
    log "  FAIL: ${interaction_id} span=${span_index} HTTP ${http_code}: ${error_msg}"
  fi
}

# ── MAIN ───────────────────────────────────────────────────────────

# Since exec_sql RPC may not exist, we'll use a simpler approach:
# Generate the span list via direct SQL through the REST API
log "Fetching target span list..."

# Use psql if DATABASE_URL is available, otherwise fall back to a pre-generated list
if [ -n "${DATABASE_URL:-}" ]; then
  SPAN_LIST=$(psql "$DATABASE_URL" -t -A -F'|' -c "
    SELECT cs.interaction_id, cs.id, cs.span_index
    FROM conversation_spans cs
    JOIN span_attributions sa ON sa.span_id = cs.id
    WHERE cs.interaction_id NOT IN (
      SELECT DISTINCT call_id FROM journal_claims WHERE call_id IS NOT NULL
    )
    AND cs.interaction_id LIKE 'cll_06%'
    AND cs.is_superseded = false
    AND (sa.applied_project_id IS NOT NULL OR sa.project_id IS NOT NULL)
    ORDER BY cs.interaction_id, cs.span_index
    $([ "$BATCH_SIZE" -gt 0 ] 2>/dev/null && echo "LIMIT $BATCH_SIZE" || true)
  ")
else
  log "WARNING: No DATABASE_URL set. Provide a span list file or set DATABASE_URL."
  log "Generating span list from Supabase MCP (use --ids-file for manual override)..."

  # Fallback: the caller can provide an IDS_FILE with pre-queried span data
  # Format: interaction_id|span_id|span_index (one per line)
  if [ -n "$IDS_FILE" ] && [ -f "$IDS_FILE" ]; then
    SPAN_LIST=$(cat "$IDS_FILE" | grep -v '^#' | grep -v '^$')
  else
    log "ERROR: No DATABASE_URL and no --ids-file provided."
    log "Generate a span list first:"
    log "  Execute the target query via Supabase MCP execute_sql and save as:"
    log "  interaction_id|span_id|span_index"
    exit 1
  fi
fi

TOTAL=$(echo "$SPAN_LIST" | grep -c '.' || true)
log "Found ${TOTAL} spans to process"

if [ "$TOTAL" -eq 0 ]; then
  log "No spans to process. Done."
  exit 0
fi

# ── PROCESS LOOP ───────────────────────────────────────────────────
COUNT=0
SUCCESS=0
FAILED=0
SKIPPED=0
DELAY_SEC=$(echo "scale=3; $BATCH_DELAY_MS / 1000" | bc)

echo "$SPAN_LIST" | while IFS='|' read -r interaction_id span_id span_index; do
  [ -z "$interaction_id" ] && continue

  COUNT=$((COUNT + 1))
  log "[${COUNT}/${TOTAL}] Processing ${interaction_id} span_index=${span_index}"

  process_span "$interaction_id" "$span_id" "$span_index"

  # Rate limit delay (skip after last item)
  if [ "$COUNT" -lt "$TOTAL" ]; then
    sleep "$DELAY_SEC"
  fi
done

# ── SUMMARY ────────────────────────────────────────────────────────
log ""
log "=== BATCH COMPLETE ==="
log "Results CSV: $RESULTS_FILE"

# Count results from CSV
if [ -f "$RESULTS_FILE" ]; then
  TOTAL_PROCESSED=$(($(wc -l < "$RESULTS_FILE") - 1))  # minus header
  OK_COUNT=$(grep -c ',ok,' "$RESULTS_FILE" || true)
  ERROR_COUNT=$(grep -c ',error_' "$RESULTS_FILE" || true)
  SKIP_COUNT=$(grep -c ',skipped' "$RESULTS_FILE" || true)
  TOTAL_CLAIMS=$(awk -F',' 'NR>1{sum+=$6}END{print sum+0}' "$RESULTS_FILE")

  log "Total processed: $TOTAL_PROCESSED"
  log "Successful: $OK_COUNT"
  log "Errors: $ERROR_COUNT"
  log "Skipped: $SKIP_COUNT"
  log "Total claims written: $TOTAL_CLAIMS"
fi

log "Done."
