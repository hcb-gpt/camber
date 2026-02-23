#!/usr/bin/env bash
set -euo pipefail

# prod_attrib_audit_reviewer_runner.sh
#
# End-to-end standing attribution audit reviewer execution:
# 1) applies reviewer output migration (idempotent)
# 2) ensures latest daily sample run is seeded
# 3) builds unreviewed packets
# 4) invokes audit-attribution-reviewer edge function
# 5) persists outputs to eval_samples + emits proof artifact bundle

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

PSQL_BIN="${PSQL_PATH:-psql}"
if [[ "${PSQL_BIN}" == */* ]]; then
  if [[ ! -x "${PSQL_BIN}" ]]; then
    echo "ERROR: psql not executable at ${PSQL_BIN}" >&2
    exit 1
  fi
else
  if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
    echo "ERROR: psql not found (set PSQL_PATH)." >&2
    exit 1
  fi
  PSQL_BIN="$(command -v "${PSQL_BIN}")"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if [[ -z "${DATABASE_URL:-}" || -z "${SUPABASE_URL:-}" || -z "${EDGE_SHARED_SECRET:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "ERROR: DATABASE_URL, SUPABASE_URL, EDGE_SHARED_SECRET, SUPABASE_SERVICE_ROLE_KEY must be set." >&2
  exit 1
fi

TARGET_SAMPLES=10
MAX_SAMPLES=40
DRY_RUN=false
SOURCE_HEADER="prod-attrib-audit-runner"
OUT_DIR="${ROOT_DIR}/artifacts/prod_attrib_audit_reviewer_runs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-samples)
      TARGET_SAMPLES="${2:-}"
      shift 2
      ;;
    --max-samples)
      MAX_SAMPLES="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  scripts/prod_attrib_audit_reviewer_runner.sh [options]

Options:
  --target-samples <n>  Minimum samples to execute before stop check (default: 10)
  --max-samples <n>     Upper bound packets to execute in one run (default: 40)
  --dry-run             Do not persist reviewer outputs
  --out-dir <path>      Artifact root override
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "${TARGET_SAMPLES}" =~ ^[0-9]+$ ]] || (( TARGET_SAMPLES < 1 )); then
  echo "ERROR: --target-samples must be >= 1" >&2
  exit 1
fi
if ! [[ "${MAX_SAMPLES}" =~ ^[0-9]+$ ]] || (( MAX_SAMPLES < TARGET_SAMPLES )); then
  echo "ERROR: --max-samples must be >= --target-samples" >&2
  exit 1
fi

MIGRATION_SQL="${ROOT_DIR}/supabase/migrations/20260223008700_add_prod_attrib_audit_output_and_dashboard.sql"
SAMPLER_SQL="${ROOT_DIR}/scripts/sql/prod_attrib_audit_sampler_and_recorder.sql"
PACKETS_SQL="${ROOT_DIR}/scripts/sql/prod_attrib_audit_pending_packets.sql"
FUNCTION_SLUG="${AUDIT_ATTRIB_REVIEW_FUNCTION_SLUG:-audit-attribution}"
FUNCTION_URL="${SUPABASE_URL}/functions/v1/${FUNCTION_SLUG}"

for f in "${MIGRATION_SQL}" "${SAMPLER_SQL}" "${PACKETS_SQL}"; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: required file missing: ${f}" >&2
    exit 1
  fi
done

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${OUT_DIR}/${TS}"
mkdir -p "${RUN_DIR}/samples"
PROCESSED_RUN_IDS_FILE="${RUN_DIR}/04_processed_run_ids.txt"
: > "${PROCESSED_RUN_IDS_FILE}"

echo "[1/5] Applying reviewer schema migration"
"${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -f "${MIGRATION_SQL}" \
  > "${RUN_DIR}/01_migration.log"

echo "[2/5] Seeding latest prod attribution audit run"
sampler_output="$("${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' -f "${SAMPLER_SQL}")"
printf '%s\n' "${sampler_output}" > "${RUN_DIR}/02_sampler.log"
sampler_run_id="$(printf '%s\n' "${sampler_output}" | awk -F $'\t' '$1 ~ /^[0-9a-fA-F-]{36}$/ {print $1; exit}')"
if [[ -z "${sampler_run_id}" ]]; then
  echo "ERROR: unable to parse eval_run_id from sampler output." >&2
  exit 1
fi
echo "sampler_eval_run_id=${sampler_run_id}" >> "${RUN_DIR}/02_sampler.log"

echo "[3/5] Building pending reviewer packets"
"${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' \
  -v eval_run_id="${sampler_run_id}" \
  -v sample_limit="${MAX_SAMPLES}" \
  -f "${PACKETS_SQL}" > "${RUN_DIR}/03_packets.tsv"

packet_count="$(awk 'NF > 0 { c += 1 } END { print c + 0 }' "${RUN_DIR}/03_packets.tsv")"
if (( packet_count < TARGET_SAMPLES )); then
  echo "INFO: seeded run produced ${packet_count} packets; backfilling from other prod_attrib_audit runs" >&2
  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' \
    -v exclude_eval_run_id="${sampler_run_id}" \
    -v sample_limit="${MAX_SAMPLES}" \
    -f "${PACKETS_SQL}" > "${RUN_DIR}/03_packets_fallback.tsv"

  awk -F $'\t' -v max_rows="${MAX_SAMPLES}" '
    BEGIN { OFS = FS; n = 0 }
    NR == FNR {
      if (NF == 0 || $3 == "") next
      seen[$3] = 1
      if (n < max_rows) {
        print
        n++
      }
      next
    }
    {
      if (NF == 0 || $3 == "") next
      if (!seen[$3] && n < max_rows) {
        print
        seen[$3] = 1
        n++
      }
    }
  ' "${RUN_DIR}/03_packets.tsv" "${RUN_DIR}/03_packets_fallback.tsv" > "${RUN_DIR}/03_packets_merged.tsv"
  mv "${RUN_DIR}/03_packets_merged.tsv" "${RUN_DIR}/03_packets.tsv"
  packet_count="$(awk 'NF > 0 { c += 1 } END { print c + 0 }' "${RUN_DIR}/03_packets.tsv")"
fi

if (( packet_count == 0 )); then
  echo "ERROR: no pending packets generated." >&2
  exit 1
fi
sampler_run_name="$(awk -F $'\t' -v rid="${sampler_run_id}" '$1 == rid { print $2; exit }' "${RUN_DIR}/03_packets.tsv")"

echo "[4/5] Executing reviewer loop"
echo "INFO: using function slug ${FUNCTION_SLUG}"
processed=0
match_count=0
mismatch_count=0
insufficient_count=0
error_count=0
latest_run_id=""
latest_run_name=""
first_mismatch_sample=""
first_mismatch_tags="[]"

while IFS=$'\t' read -r eval_run_id eval_run_name eval_sample_id sample_rank packet_b64; do
  [[ -z "${eval_sample_id}" ]] && continue
  latest_run_id="${eval_run_id}"
  latest_run_name="${eval_run_name}"
  printf '%s\n' "${eval_run_id}" >> "${PROCESSED_RUN_IDS_FILE}"

  packet_json="$(jq -rn --arg b "${packet_b64}" '$b | @base64d')"
  payload="$(jq -nc \
    --arg eval_sample_id "${eval_sample_id}" \
    --argjson audit_packet "${packet_json}" \
    --argjson persist "$( [[ "${DRY_RUN}" == "true" ]] && echo false || echo true )" \
    --argjson dry_run "$( [[ "${DRY_RUN}" == "true" ]] && echo true || echo false )" \
    '{eval_sample_id:$eval_sample_id, audit_packet:$audit_packet, persist:$persist, dry_run:$dry_run}')"

  response="$(curl -sS -w $'\n%{http_code}' -X POST "${FUNCTION_URL}" \
    -H "Content-Type: application/json" \
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
    -H "X-Source: ${SOURCE_HEADER}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -d "${payload}")"
  http_code="$(printf '%s' "${response}" | tail -n1)"
  body="$(printf '%s' "${response}" | sed '$d')"

  printf '%s\n' "${body}" > "${RUN_DIR}/samples/${sample_rank}_${eval_run_id}_${eval_sample_id}.json"

  if [[ "${http_code}" != "200" ]]; then
    echo "WARN: sample ${eval_sample_id} returned HTTP ${http_code}" >&2
    error_count=$((error_count + 1))
    processed=$((processed + 1))
    continue
  fi

  ok_flag="$(printf '%s' "${body}" | jq -r '.ok // false')"
  if [[ "${ok_flag}" != "true" ]]; then
    echo "WARN: sample ${eval_sample_id} returned ok=false" >&2
    error_count=$((error_count + 1))
    processed=$((processed + 1))
    continue
  fi

  verdict="$(printf '%s' "${body}" | jq -r '.reviewer_output.verdict // "UNKNOWN"')"
  tags="$(printf '%s' "${body}" | jq -c '.reviewer_output.failure_mode_tags // []')"
  case "${verdict}" in
    MATCH) match_count=$((match_count + 1)) ;;
    MISMATCH)
      mismatch_count=$((mismatch_count + 1))
      if [[ -z "${first_mismatch_sample}" ]]; then
        first_mismatch_sample="${eval_sample_id}"
        first_mismatch_tags="${tags}"
      fi
      ;;
    INSUFFICIENT) insufficient_count=$((insufficient_count + 1)) ;;
    *)
      error_count=$((error_count + 1))
      ;;
  esac

  processed=$((processed + 1))
  if (( processed >= TARGET_SAMPLES && mismatch_count >= 1 )); then
    break
  fi
  if (( processed >= MAX_SAMPLES )); then
    break
  fi
done < "${RUN_DIR}/03_packets.tsv"

if [[ -z "${latest_run_id}" ]]; then
  echo "ERROR: could not determine latest eval run id from packet stream." >&2
  exit 1
fi
processed_run_ids_csv="$(sort -u "${PROCESSED_RUN_IDS_FILE}" | sed '/^$/d' | paste -sd, -)"
processed_run_ids_json="$(sort -u "${PROCESSED_RUN_IDS_FILE}" | sed '/^$/d' | jq -R . | jq -s .)"
if [[ -z "${processed_run_ids_csv}" ]]; then
  echo "ERROR: no processed eval_run_ids recorded." >&2
  exit 1
fi

echo "[5/5] Collecting DB proof snapshot"
"${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 <<SQL > "${RUN_DIR}/05_db_proof.txt"
\pset pager off
with target_runs as (
  select unnest(string_to_array('${processed_run_ids_csv}', ','))::uuid as eval_run_id
)
select
  er.id as eval_run_id,
  er.name as eval_run_name,
  count(*)::int as total_samples,
  count(*) filter (where reviewer_verdict is not null)::int as reviewed_samples,
  count(*) filter (where reviewer_verdict = 'MATCH')::int as match_count,
  count(*) filter (where reviewer_verdict = 'MISMATCH')::int as mismatch_count,
  count(*) filter (where reviewer_verdict = 'INSUFFICIENT')::int as insufficient_count
from target_runs tr
join public.eval_runs er on er.id = tr.eval_run_id
join public.eval_samples es on es.eval_run_id = tr.eval_run_id
group by er.id, er.name
order by er.created_at desc;

with target_runs as (
  select unnest(string_to_array('${processed_run_ids_csv}', ','))::uuid as eval_run_id
)
select
  es.eval_run_id,
  es.id as eval_sample_id,
  es.sample_rank,
  es.interaction_id,
  es.span_id,
  es.reviewer_verdict,
  es.reviewer_failure_mode_tags,
  es.reviewer_completed_at
from public.eval_samples es
where es.eval_run_id in (select eval_run_id from target_runs)
  and es.reviewer_verdict = 'MISMATCH'
order by es.reviewer_completed_at desc nulls last, es.sample_rank
limit 10;
SQL

pass_condition=false
if (( processed >= TARGET_SAMPLES && mismatch_count >= 1 && error_count == 0 )); then
  pass_condition=true
fi

cat > "${RUN_DIR}/summary.json" <<EOF
{
  "timestamp_utc": "${TS}",
  "sampler_eval_run_id": "${sampler_run_id}",
  "sampler_eval_run_name": "${sampler_run_name}",
  "eval_run_id": "${latest_run_id}",
  "eval_run_name": "${latest_run_name}",
  "function_slug": "${FUNCTION_SLUG}",
  "function_url": "${FUNCTION_URL}",
  "processed_eval_run_ids": ${processed_run_ids_json},
  "dry_run": ${DRY_RUN},
  "target_samples": ${TARGET_SAMPLES},
  "max_samples": ${MAX_SAMPLES},
  "processed": ${processed},
  "match_count": ${match_count},
  "mismatch_count": ${mismatch_count},
  "insufficient_count": ${insufficient_count},
  "error_count": ${error_count},
  "first_mismatch_sample": "${first_mismatch_sample}",
  "first_mismatch_tags": ${first_mismatch_tags},
  "pass_condition": ${pass_condition},
  "artifacts": {
    "migration_log": "${RUN_DIR}/01_migration.log",
    "sampler_log": "${RUN_DIR}/02_sampler.log",
    "packets_tsv": "${RUN_DIR}/03_packets.tsv",
    "db_proof": "${RUN_DIR}/05_db_proof.txt"
  }
}
EOF

echo "RUN_DIR=${RUN_DIR}"
echo "SUMMARY_JSON=${RUN_DIR}/summary.json"
echo "PROCESSED=${processed} MATCH=${match_count} MISMATCH=${mismatch_count} INSUFFICIENT=${insufficient_count} ERRORS=${error_count}"

if [[ "${pass_condition}" != "true" ]]; then
  echo "ERROR: pass condition failed (need >=${TARGET_SAMPLES} processed and >=1 mismatch with zero execution errors)." >&2
  exit 1
fi
