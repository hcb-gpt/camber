#!/usr/bin/env bash
set -euo pipefail

# One-command canary for striking-signals call traceability.
# Outputs: missing_call_id_7d + delta_vs_prev + GO_NO_GO, with downstream snapshots.
#
# Usage:
#   scripts/striking_traceability_regression_canary.sh
#   CANARY_THRESHOLD_MISSING_CALL_ID=0 scripts/striking_traceability_regression_canary.sh
#
# Exit codes:
#   0 = GO
#   3 = NO_GO (threshold breached)
#   2 = environment/config error

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh"

PSQL_BIN="${PSQL_PATH:-psql}"
if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
  echo "ERROR: psql not found (set PSQL_PATH or install psql)." >&2
  exit 2
fi
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL missing after env load." >&2
  exit 2
fi

STATE_FILE="${CANARY_STATE_FILE:-${ROOT_DIR}/.temp/striking_traceability_canary.state}"
THRESHOLD_MISSING_CALL_ID="${CANARY_THRESHOLD_MISSING_CALL_ID:-0}"
mkdir -p "$(dirname "${STATE_FILE}")"

if [[ ! "${THRESHOLD_MISSING_CALL_ID}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CANARY_THRESHOLD_MISSING_CALL_ID must be a non-negative integer." >&2
  exit 2
fi

readout_sql="$(cat <<'SQL'
with ss as (
  select
    count(*)::bigint as ss_rows_7d,
    count(*) filter (where call_id is null or call_id = '')::bigint as ss_missing_call_id_7d
  from public.striking_signals
  where created_at >= now() - interval '7 days'
), es as (
  select
    count(*)::bigint as es_rows,
    count(*) filter (where has_striking)::bigint as es_has_striking_true
  from public.enrichment_scorecard
), pf as (
  select
    count(*)::bigint as pf_rows,
    coalesce(sum(striking_signal_count), 0)::bigint as pf_total_striking
  from public.v_project_feed
), mm as (
  select
    count(*)::bigint as mm_rows,
    coalesce(sum(new_striking_signals), 0)::bigint as mm_total_new_striking
  from public.v_morning_manifest
)
select
  ss.ss_rows_7d,
  ss.ss_missing_call_id_7d,
  es.es_rows,
  es.es_has_striking_true,
  pf.pf_rows,
  pf.pf_total_striking,
  mm.mm_rows,
  mm.mm_total_new_striking
from ss, es, pf, mm;
SQL
)"

row="$(${PSQL_BIN} "${DATABASE_URL}" -X -A -t -F '|' -v ON_ERROR_STOP=1 -c "${readout_sql}")"
IFS='|' read -r \
  ss_rows_7d \
  ss_missing_call_id_7d \
  es_rows \
  es_has_striking_true \
  pf_rows \
  pf_total_striking \
  mm_rows \
  mm_total_new_striking <<< "${row}"

now_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
prev_ts=""
prev_ss_rows_7d=""
prev_ss_missing_call_id_7d=""
prev_es_has_striking_true=""
prev_pf_total_striking=""
prev_mm_total_new_striking=""

if [[ -f "${STATE_FILE}" ]]; then
  IFS='|' read -r \
    prev_ts \
    prev_ss_rows_7d \
    prev_ss_missing_call_id_7d \
    prev_es_has_striking_true \
    prev_pf_total_striking \
    prev_mm_total_new_striking < "${STATE_FILE}" || true
fi

if [[ -z "${prev_ss_missing_call_id_7d}" ]]; then
  delta_missing_call_id=0
  delta_ss_rows_7d=0
  delta_es_has_striking_true=0
  delta_pf_total_striking=0
  delta_mm_total_new_striking=0
else
  delta_missing_call_id=$((ss_missing_call_id_7d - prev_ss_missing_call_id_7d))
  delta_ss_rows_7d=$((ss_rows_7d - prev_ss_rows_7d))
  delta_es_has_striking_true=$((es_has_striking_true - prev_es_has_striking_true))
  delta_pf_total_striking=$((pf_total_striking - prev_pf_total_striking))
  delta_mm_total_new_striking=$((mm_total_new_striking - prev_mm_total_new_striking))
fi

if (( ss_missing_call_id_7d <= THRESHOLD_MISSING_CALL_ID )); then
  go_no_go="GO"
  reason="within_thresholds"
  stop_condition="none"
  exit_code=0
else
  go_no_go="NO_GO"
  reason="missing_call_id_7d>${THRESHOLD_MISSING_CALL_ID}"
  stop_condition="pause writes touching striking_signals; run bounded backfill call_id:=interaction_id for recent nulls; escalate with proof"
  exit_code=3
fi

printf "%s|%s|%s|%s|%s|%s\n" \
  "${now_utc}" \
  "${ss_rows_7d}" \
  "${ss_missing_call_id_7d}" \
  "${es_has_striking_true}" \
  "${pf_total_striking}" \
  "${mm_total_new_striking}" > "${STATE_FILE}"

echo "CANARY_TS_UTC=${now_utc}"
echo "MISSING_CALL_ID_7D=${ss_missing_call_id_7d}"
echo "DELTA_VS_PREV_MISSING_CALL_ID_7D=${delta_missing_call_id}"
echo "SS_ROWS_7D=${ss_rows_7d}"
echo "DELTA_VS_PREV_SS_ROWS_7D=${delta_ss_rows_7d}"
echo "DOWNSTREAM_ENRICHMENT_HAS_STRIKING=${es_has_striking_true}"
echo "DELTA_VS_PREV_ENRICHMENT_HAS_STRIKING=${delta_es_has_striking_true}"
echo "DOWNSTREAM_PROJECT_FEED_TOTAL_STRIKING=${pf_total_striking}"
echo "DELTA_VS_PREV_PROJECT_FEED_TOTAL_STRIKING=${delta_pf_total_striking}"
echo "DOWNSTREAM_MORNING_NEW_STRIKING=${mm_total_new_striking}"
echo "DELTA_VS_PREV_MORNING_NEW_STRIKING=${delta_mm_total_new_striking}"
echo "THRESHOLD_MISSING_CALL_ID_7D=${THRESHOLD_MISSING_CALL_ID}"
echo "GO_NO_GO=${go_no_go}"
echo "REASON=${reason}"
echo "STOP_CONDITION=${stop_condition}"
echo "BUDDY_HANDOFF=DEV/STRAT can run this same command and compare missing/delta/go_no_go without translation"

exit "${exit_code}"
