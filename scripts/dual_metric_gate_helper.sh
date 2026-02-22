#!/usr/bin/env bash
set -euo pipefail

# dual_metric_gate_helper.sh
# One-command helper for journal persistence gate checks.
#
# Emits:
# - metric_b_calls (historical monitor)
# - metric_c_latest_calls (closure gate)
# - missing_embedding_24h
# - GO_NO_GO line based on thresholded closure gate
#
# Usage:
#   ./scripts/dual_metric_gate_helper.sh
#   ./scripts/dual_metric_gate_helper.sh --json
#   ./scripts/dual_metric_gate_helper.sh --window-hours 24 --max-latest-calls 0 --max-missing-embedding 0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

WINDOW_HOURS=24
MAX_LATEST_CALLS=0
MAX_MISSING_EMBEDDING=0
JSON_OUTPUT=false

usage() {
  cat <<'USAGE'
Usage: scripts/dual_metric_gate_helper.sh [options]

Options:
  --window-hours N           Lookback window in hours (default: 24)
  --max-latest-calls N       GO threshold for metric_c_latest_calls (default: 0)
  --max-missing-embedding N  GO threshold for missing_embedding_24h (default: 0)
  --json                     Emit JSON instead of text lines
  -h, --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-hours)
      WINDOW_HOURS="${2:-}"
      shift 2
      ;;
    --max-latest-calls)
      MAX_LATEST_CALLS="${2:-}"
      shift 2
      ;;
    --max-missing-embedding)
      MAX_MISSING_EMBEDDING="${2:-}"
      shift 2
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
      exit 2
      ;;
  esac
done

for n in "$WINDOW_HOURS" "$MAX_LATEST_CALLS" "$MAX_MISSING_EMBEDDING"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "ERROR: numeric options must be non-negative integers." >&2
    exit 2
  fi
done

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL is not set after loading env." >&2
  exit 1
fi

PSQL_BIN="${PSQL_PATH:-psql}"
if [[ "${PSQL_BIN}" == */* ]]; then
  if [[ ! -x "${PSQL_BIN}" ]]; then
    echo "ERROR: psql not executable at PSQL_PATH=${PSQL_BIN}" >&2
    exit 1
  fi
else
  if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
    echo "ERROR: psql not found in PATH (or set PSQL_PATH)." >&2
    exit 1
  fi
fi

SQL="
with runs as (
  select
    run_id,
    call_id,
    started_at,
    status,
    coalesce(config->>'mode','(null)') as mode,
    coalesce(claims_extracted,0) as claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
    and started_at >= now() - ('${WINDOW_HOURS} hours')::interval
    and call_id !~ '^cll_lineage_test_'
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), joined as (
  select
    r.*,
    coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
), metric_b as (
  select distinct call_id
  from joined
  where claim_rows = 0
    and not (mode='consolidate' and status='success')
), ranked as (
  select
    j.*,
    row_number() over (partition by j.call_id order by j.started_at desc) as rn
  from joined j
), metric_c as (
  select distinct call_id
  from ranked
  where rn = 1
    and claim_rows = 0
    and not (mode='consolidate' and status='success')
), missing as (
  select count(*) filter (
    where created_at >= now() - ('${WINDOW_HOURS} hours')::interval
      and embedding is null
  )::int as missing_embedding
  from public.journal_claims
)
select
  to_char(now() at time zone 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as ts_utc,
  (select count(*) from metric_b) as metric_b_calls,
  (select count(*) from metric_c) as metric_c_latest_calls,
  (select missing_embedding from missing) as missing_embedding_24h;
"

RESULT="$("${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "${SQL}")"

IFS=$'\t' read -r TS_UTC METRIC_B_CALLS METRIC_C_LATEST_CALLS MISSING_EMBEDDING_24H <<<"${RESULT}"

GO_NO_GO="GO"
REASONS=()
if (( METRIC_C_LATEST_CALLS > MAX_LATEST_CALLS )); then
  GO_NO_GO="NO_GO"
  REASONS+=("metric_c_latest_calls>${MAX_LATEST_CALLS}")
fi
if (( MISSING_EMBEDDING_24H > MAX_MISSING_EMBEDDING )); then
  GO_NO_GO="NO_GO"
  REASONS+=("missing_embedding_24h>${MAX_MISSING_EMBEDDING}")
fi

REASON="within_thresholds"
if (( ${#REASONS[@]} > 0 )); then
  REASON="$(IFS=','; echo "${REASONS[*]}")"
fi

if [[ "${JSON_OUTPUT}" == "true" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for --json output." >&2
    exit 1
  fi
  jq -n \
    --arg ts_utc "${TS_UTC}" \
    --argjson window_hours "${WINDOW_HOURS}" \
    --argjson metric_b_calls "${METRIC_B_CALLS}" \
    --argjson metric_c_latest_calls "${METRIC_C_LATEST_CALLS}" \
    --argjson missing_embedding_24h "${MISSING_EMBEDDING_24H}" \
    --arg go_no_go "${GO_NO_GO}" \
    --arg reason "${REASON}" \
    --arg gate_rule "metric_c_latest_calls<=${MAX_LATEST_CALLS} && missing_embedding_24h<=${MAX_MISSING_EMBEDDING}" \
    '{
      ts_utc: $ts_utc,
      window_hours: $window_hours,
      metric_b_calls: $metric_b_calls,
      metric_c_latest_calls: $metric_c_latest_calls,
      missing_embedding_24h: $missing_embedding_24h,
      go_no_go: $go_no_go,
      reason: $reason,
      gate_rule: $gate_rule
    }'
  exit 0
fi

echo "METRICS ts_utc=${TS_UTC} metric_b_calls=${METRIC_B_CALLS} metric_c_latest_calls=${METRIC_C_LATEST_CALLS} missing_embedding_24h=${MISSING_EMBEDDING_24H}"
echo "GO_NO_GO=${GO_NO_GO} reason=${REASON} gate_rule=\"metric_c_latest_calls<=${MAX_LATEST_CALLS} && missing_embedding_24h<=${MAX_MISSING_EMBEDDING}\""
