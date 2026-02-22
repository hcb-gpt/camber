#!/usr/bin/env bash
set -euo pipefail

# consolidation_delta_probe.sh
# Probe consolidation output deltas for a specific journal run.
#
# Usage:
#   ./scripts/consolidation_delta_probe.sh --run-id <uuid>
#   ./scripts/consolidation_delta_probe.sh --run-id <uuid> --no-invoke
#   ./scripts/consolidation_delta_probe.sh --run-id <uuid> --json
#
# Requires: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EDGE_SHARED_SECRET

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh"

RUN_ID=""
DO_INVOKE=true
JSON_OUTPUT=false

usage() {
  cat <<USAGE
Usage: $0 --run-id <uuid> [--no-invoke] [--json]

Options:
  --run-id <uuid>  Target journal_runs.run_id to probe (required)
  --no-invoke      Skip edge invocation; only report current counts
  --json           Emit JSON payload at end
  -h, --help       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --no-invoke)
      DO_INVOKE=false
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "ERROR: --run-id is required." >&2
  usage >&2
  exit 1
fi

for var in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY EDGE_SHARED_SECRET; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Missing required env var: ${var}" >&2
    exit 1
  fi
done

for bin in curl jq rg awk; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: ${bin} is required." >&2
    exit 1
  fi
done

BASE="$SUPABASE_URL"
AUTH_HEADER="apikey: $SUPABASE_SERVICE_ROLE_KEY"
BEARER_HEADER="Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"

fetch_total_count() {
  local table="$1"
  curl -sS -G "$BASE/rest/v1/${table}" \
    -H "$AUTH_HEADER" \
    -H "$BEARER_HEADER" \
    --data-urlencode "select=id" \
    --data-urlencode "limit=1" \
    -H "Prefer: count=exact" \
    -D - -o /dev/null \
    | rg -i "content-range" \
    | awk -F'/' '{print $2}' \
    | tr -d '\r'
}

fetch_filtered_count() {
  local table="$1"
  local filter="$2"
  curl -sS -G "$BASE/rest/v1/${table}" \
    -H "$AUTH_HEADER" \
    -H "$BEARER_HEADER" \
    --data-urlencode "select=id" \
    --data-urlencode "$filter" \
    -H "Prefer: count=exact" \
    -D - -o /dev/null \
    | rg -i "content-range" \
    | awk -F'/' '{print $2}' \
    | tr -d '\r'
}

fetch_run_meta() {
  curl -sS -G "$BASE/rest/v1/journal_runs" \
    -H "$AUTH_HEADER" \
    -H "$BEARER_HEADER" \
    --data-urlencode "select=run_id,status,project_id,call_id,claims_extracted,started_at,completed_at,error_message" \
    --data-urlencode "run_id=eq.${RUN_ID}" \
    --data-urlencode "limit=1"
}

before_module_claims="$(fetch_total_count "module_claims")"
before_module_receipts="$(fetch_total_count "module_receipts")"
run_journal_claims="$(fetch_filtered_count "journal_claims" "run_id=eq.${RUN_ID}")"
run_meta_json="$(fetch_run_meta)"
run_exists="$(jq 'length' <<<"$run_meta_json")"

if [[ "$run_exists" -eq 0 ]]; then
  echo "ERROR: run_id not found in journal_runs: ${RUN_ID}" >&2
  exit 1
fi

run_status="$(jq -r '.[0].status // "unknown"' <<<"$run_meta_json")"
run_project_id="$(jq -r '.[0].project_id // ""' <<<"$run_meta_json")"
run_call_id="$(jq -r '.[0].call_id // ""' <<<"$run_meta_json")"
run_claims_extracted="$(jq -r '.[0].claims_extracted // 0' <<<"$run_meta_json")"

invoke_response='{"ok":false,"reason":"invoke_skipped"}'
invoke_http_code="SKIPPED"

if [[ "$DO_INVOKE" == "true" ]]; then
  invoke_raw="$({
    curl -sS -w $'\n%{http_code}' -X POST "$BASE/functions/v1/journal-consolidate" \
      -H "$AUTH_HEADER" \
      -H "$BEARER_HEADER" \
      -H "X-Edge-Secret: $EDGE_SHARED_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"run_id\":\"$RUN_ID\"}" \
      --max-time 120
  } || true)"

  invoke_http_code="$(echo "$invoke_raw" | tail -n1)"
  invoke_response="$(echo "$invoke_raw" | sed '$d')"
fi

after_module_claims="$(fetch_total_count "module_claims")"
after_module_receipts="$(fetch_total_count "module_receipts")"

delta_module_claims=$((after_module_claims - before_module_claims))
delta_module_receipts=$((after_module_receipts - before_module_receipts))

echo "=== Consolidation Delta Probe ==="
echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "run_id: ${RUN_ID}"
echo "run_status: ${run_status}"
echo "project_id: ${run_project_id:-none}"
echo "call_id: ${run_call_id:-none}"
echo "journal_runs.claims_extracted: ${run_claims_extracted}"
echo "journal_claims_for_run: ${run_journal_claims}"
echo "module_claims: ${before_module_claims} -> ${after_module_claims} (delta=${delta_module_claims})"
echo "module_receipts: ${before_module_receipts} -> ${after_module_receipts} (delta=${delta_module_receipts})"
echo "invoke_http_code: ${invoke_http_code}"
echo "invoke_response: ${invoke_response}"

echo "CONSOLIDATION_DELTA_PROBE run_id=${RUN_ID} run_status=${run_status} run_claims_extracted=${run_claims_extracted} journal_claims_for_run=${run_journal_claims} module_claims_before=${before_module_claims} module_claims_after=${after_module_claims} module_claims_delta=${delta_module_claims} module_receipts_before=${before_module_receipts} module_receipts_after=${after_module_receipts} module_receipts_delta=${delta_module_receipts} invoke_http_code=${invoke_http_code} timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg run_status "$run_status" \
    --arg project_id "$run_project_id" \
    --arg call_id "$run_call_id" \
    --argjson run_claims_extracted "$run_claims_extracted" \
    --argjson journal_claims_for_run "$run_journal_claims" \
    --argjson module_claims_before "$before_module_claims" \
    --argjson module_claims_after "$after_module_claims" \
    --argjson module_claims_delta "$delta_module_claims" \
    --argjson module_receipts_before "$before_module_receipts" \
    --argjson module_receipts_after "$after_module_receipts" \
    --argjson module_receipts_delta "$delta_module_receipts" \
    --arg invoke_http_code "$invoke_http_code" \
    --arg invoke_response_raw "$invoke_response" \
    '{
      run_id: $run_id,
      run_status: $run_status,
      project_id: $project_id,
      call_id: $call_id,
      run_claims_extracted: $run_claims_extracted,
      journal_claims_for_run: $journal_claims_for_run,
      module_claims_before: $module_claims_before,
      module_claims_after: $module_claims_after,
      module_claims_delta: $module_claims_delta,
      module_receipts_before: $module_receipts_before,
      module_receipts_after: $module_receipts_after,
      module_receipts_delta: $module_receipts_delta,
      invoke_http_code: $invoke_http_code,
      invoke_response: (try ($invoke_response_raw | fromjson) catch {raw: $invoke_response_raw}),
      timestamp: (now | todate)
    }'
fi
