#!/usr/bin/env bash
set -euo pipefail

# embed_acceptance_watch.sh
# Capture and compare embed-freshness acceptance metrics for quick DATA/DEV closures.
#
# Usage:
#   scripts/embed_acceptance_watch.sh --write-baseline
#   scripts/embed_acceptance_watch.sh --compare
#   scripts/embed_acceptance_watch.sh --baseline-file .temp/custom_baseline.json --compare --json

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

BASELINE_FILE="${ROOT_DIR}/.temp/embed_acceptance_baseline.json"
WRITE_BASELINE=false
COMPARE=false
JSON_OUTPUT=false
MAX_RUNID_MISMATCH_INCREASE=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --write-baseline                 Save current metrics as baseline
  --compare                        Compare current metrics against baseline
  --baseline-file <path>           Baseline json path (default: .temp/embed_acceptance_baseline.json)
  --max-runid-mismatch-increase N  Allowed increase for runid_mismatch_24h (default: 0)
  --json                           Emit machine-readable JSON summary
  -h, --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write-baseline)
      WRITE_BASELINE=true
      shift
      ;;
    --compare)
      COMPARE=true
      shift
      ;;
    --baseline-file)
      BASELINE_FILE="${2:-}"
      shift 2
      ;;
    --max-runid-mismatch-increase)
      MAX_RUNID_MISMATCH_INCREASE="${2:-0}"
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

if [[ "${WRITE_BASELINE}" == "false" && "${COMPARE}" == "false" ]]; then
  echo "ERROR: choose at least one mode: --write-baseline and/or --compare" >&2
  usage >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required." >&2
  exit 2
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL is required." >&2
  exit 2
fi

PSQL_BIN="${PSQL_PATH:-psql}"
if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
  echo "ERROR: psql not found (set PSQL_PATH if needed)." >&2
  exit 2
fi

snapshot_json() {
  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -P pager=off -At <<'SQL'
with base as (
  select
    count(*) filter (where jc.embedding is null) as missing_embedding_all,
    count(*) filter (where jc.embedding is null and jc.created_at >= now() - interval '24 hours') as missing_embedding_24h,
    count(*) filter (where jc.embedding is not null and jc.created_at >= now() - interval '24 hours') as embedded_24h
  from public.journal_claims jc
), runs_pos as (
  select run_id, started_at
  from public.journal_runs
  where coalesce(claims_extracted, 0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mismatch as (
  select
    count(*) filter (where r.started_at >= now() - interval '24 hours' and coalesce(c.claim_rows,0)=0) as runid_mismatch_24h
  from runs_pos r
  left join claim_counts c on c.run_id = r.run_id
)
select json_build_object(
  'captured_at_utc', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'missing_embedding_all', base.missing_embedding_all,
  'missing_embedding_24h', base.missing_embedding_24h,
  'embedded_24h', base.embedded_24h,
  'runid_mismatch_24h', mismatch.runid_mismatch_24h
)::text
from base, mismatch;
SQL
}

CURRENT_JSON="$(snapshot_json)"

if [[ "${WRITE_BASELINE}" == "true" ]]; then
  mkdir -p "$(dirname "${BASELINE_FILE}")"
  printf '%s\n' "${CURRENT_JSON}" > "${BASELINE_FILE}"
fi

if [[ "${COMPARE}" == "true" ]]; then
  if [[ ! -f "${BASELINE_FILE}" ]]; then
    echo "ERROR: baseline file not found: ${BASELINE_FILE}" >&2
    exit 2
  fi

  BASELINE_JSON="$(cat "${BASELINE_FILE}")"

  SUMMARY_JSON="$(jq -n \
    --argjson b "${BASELINE_JSON}" \
    --argjson c "${CURRENT_JSON}" \
    --argjson max_inc "${MAX_RUNID_MISMATCH_INCREASE}" \
    '
      {
        baseline: $b,
        current: $c,
        delta: {
          missing_embedding_all: ($c.missing_embedding_all - $b.missing_embedding_all),
          missing_embedding_24h: ($c.missing_embedding_24h - $b.missing_embedding_24h),
          embedded_24h: ($c.embedded_24h - $b.embedded_24h),
          runid_mismatch_24h: ($c.runid_mismatch_24h - $b.runid_mismatch_24h)
        }
      }
      | .verdict = (
          if (
               (
                 (.delta.embedded_24h > 0 and .delta.missing_embedding_24h < 0)
                 or
                 (.current.embedded_24h > 0 and .current.missing_embedding_24h == 0)
               )
               and (.delta.runid_mismatch_24h <= $max_inc)
             )
          then "PASS" else "FAIL" end
        )
      | .reason = (
          if .verdict != "PASS" then
            "one or more acceptance conditions not met"
          elif (.delta.embedded_24h > 0 and .delta.missing_embedding_24h < 0) then
            "24h embedding throughput improved and runid mismatch stayed within threshold"
          else
            "healthy steady-state maintained and runid mismatch stayed within threshold"
          end
        )
    ')"

  if [[ "${JSON_OUTPUT}" == "true" ]]; then
    printf '%s\n' "${SUMMARY_JSON}"
  else
    echo "=== Embed Acceptance Watch ==="
    echo "BASELINE_AT=$(jq -r '.baseline.captured_at_utc' <<<"${SUMMARY_JSON}")"
    echo "CURRENT_AT=$(jq -r '.current.captured_at_utc' <<<"${SUMMARY_JSON}")"
    echo "BASELINE missing_embedding_all=$(jq -r '.baseline.missing_embedding_all' <<<"${SUMMARY_JSON}") missing_embedding_24h=$(jq -r '.baseline.missing_embedding_24h' <<<"${SUMMARY_JSON}") embedded_24h=$(jq -r '.baseline.embedded_24h' <<<"${SUMMARY_JSON}") runid_mismatch_24h=$(jq -r '.baseline.runid_mismatch_24h' <<<"${SUMMARY_JSON}")"
    echo "CURRENT  missing_embedding_all=$(jq -r '.current.missing_embedding_all' <<<"${SUMMARY_JSON}") missing_embedding_24h=$(jq -r '.current.missing_embedding_24h' <<<"${SUMMARY_JSON}") embedded_24h=$(jq -r '.current.embedded_24h' <<<"${SUMMARY_JSON}") runid_mismatch_24h=$(jq -r '.current.runid_mismatch_24h' <<<"${SUMMARY_JSON}")"
    echo "DELTA    missing_embedding_all=$(jq -r '.delta.missing_embedding_all' <<<"${SUMMARY_JSON}") missing_embedding_24h=$(jq -r '.delta.missing_embedding_24h' <<<"${SUMMARY_JSON}") embedded_24h=$(jq -r '.delta.embedded_24h' <<<"${SUMMARY_JSON}") runid_mismatch_24h=$(jq -r '.delta.runid_mismatch_24h' <<<"${SUMMARY_JSON}")"
    echo "VERDICT=$(jq -r '.verdict' <<<"${SUMMARY_JSON}")"
    echo "REASON=$(jq -r '.reason' <<<"${SUMMARY_JSON}")"
  fi

  if [[ "$(jq -r '.verdict' <<<"${SUMMARY_JSON}")" != "PASS" ]]; then
    exit 1
  fi

  exit 0
fi

if [[ "${JSON_OUTPUT}" == "true" ]]; then
  printf '%s\n' "${CURRENT_JSON}"
else
  echo "BASELINE_WRITTEN=${BASELINE_FILE}"
  echo "SNAPSHOT=${CURRENT_JSON}"
fi
