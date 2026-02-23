#!/usr/bin/env bash
set -euo pipefail

# verify_audit_attribution_packet_v1.sh
#
# One-command verification for packet-v1 reviewer path:
# 1) Build a seeded packet from SQL
# 2) Invoke audit-attribution with raw packet-v1 (no field adaptation)
# 3) Persist proof artifacts
#
# Usage:
#   scripts/verify_audit_attribution_packet_v1.sh
#   scripts/verify_audit_attribution_packet_v1.sh --sample-seed 0.314159 --sample-limit 1 --lookback-hours 48

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

if [[ -z "${DATABASE_URL:-}" || -z "${SUPABASE_URL:-}" || -z "${EDGE_SHARED_SECRET:-}" ]]; then
  echo "ERROR: DATABASE_URL, SUPABASE_URL, EDGE_SHARED_SECRET must be set." >&2
  exit 1
fi

SAMPLE_SEED="0.314159"
SAMPLE_LIMIT="1"
LOOKBACK_HOURS="48"
OUT_DIR="${ROOT_DIR}/artifacts/attribution_audit_packet_verify/$(date -u +%Y%m%dT%H%M%SZ)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-seed)
      SAMPLE_SEED="${2:-}"
      shift 2
      ;;
    --sample-limit)
      SAMPLE_LIMIT="${2:-}"
      shift 2
      ;;
    --lookback-hours)
      LOOKBACK_HOURS="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  scripts/verify_audit_attribution_packet_v1.sh [options]

Options:
  --sample-seed <float>    Seed passed to packet SQL (default: 0.314159)
  --sample-limit <int>     Number of packets from SQL (default: 1)
  --lookback-hours <int>   Lookback window for packet SQL (default: 48)
  --out-dir <path>         Output directory override
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${OUT_DIR}"

PACKET_SQL="${ROOT_DIR}/scripts/sql/attribution_audit_packet_v1.sql"
if [[ ! -f "${PACKET_SQL}" ]]; then
  echo "ERROR: missing SQL file: ${PACKET_SQL}" >&2
  exit 1
fi

echo "[1/3] Building packet-v1 from SQL"
"${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 \
  -P format=unaligned -P tuples_only=on \
  -v sample_seed="${SAMPLE_SEED}" \
  -v sample_limit="${SAMPLE_LIMIT}" \
  -v lookback_hours="${LOOKBACK_HOURS}" \
  -f "${PACKET_SQL}" > "${OUT_DIR}/01_packet_sql_output.txt"

PACKET_JSON="$(tail -n1 "${OUT_DIR}/01_packet_sql_output.txt")"
if [[ -z "${PACKET_JSON}" ]]; then
  echo "ERROR: SQL output was empty." >&2
  exit 1
fi
if ! jq -e . >/dev/null <<<"${PACKET_JSON}"; then
  echo "ERROR: packet SQL did not return valid JSON in final row." >&2
  exit 1
fi
printf '%s\n' "${PACKET_JSON}" > "${OUT_DIR}/02_packet_raw.json"

echo "[2/3] Invoking audit-attribution with raw packet-v1"
REVIEWER_RUN_ID="verify_packet_v1_$(date -u +%Y%m%dT%H%M%SZ)"
jq -cn \
  --argjson audit_packet "${PACKET_JSON}" \
  --arg reviewer_run_id "${REVIEWER_RUN_ID}" \
  '{audit_packet:$audit_packet,persist:false,dry_run:true,reviewer_run_id:$reviewer_run_id}' \
  > "${OUT_DIR}/03_request_payload.json"

RAW_RESPONSE="$(curl -sS -w $'\n%{http_code}' -X POST "${SUPABASE_URL}/functions/v1/audit-attribution" \
  -H "Content-Type: application/json" \
  -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
  -H "X-Source: audit-attribution-test" \
  -d @"${OUT_DIR}/03_request_payload.json")"
printf '%s\n' "${RAW_RESPONSE}" > "${OUT_DIR}/04_response_with_status.txt"

HTTP_CODE="$(tail -n1 "${OUT_DIR}/04_response_with_status.txt")"
sed '$d' "${OUT_DIR}/04_response_with_status.txt" > "${OUT_DIR}/05_response_body.json"

echo "[3/3] Verification summary"
echo "OUT_DIR=${OUT_DIR}"
echo "HTTP_STATUS=${HTTP_CODE}"
echo "REVIEWER_RUN_ID=${REVIEWER_RUN_ID}"

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: reviewer invocation failed; see ${OUT_DIR}/04_response_with_status.txt" >&2
  exit 1
fi

if ! jq -e '.ok == true and (.reviewer_output.verdict | type == "string")' "${OUT_DIR}/05_response_body.json" >/dev/null; then
  echo "ERROR: unexpected response schema; see ${OUT_DIR}/05_response_body.json" >&2
  exit 1
fi

echo "VERDICT=$(jq -r '.reviewer_output.verdict' "${OUT_DIR}/05_response_body.json")"
echo "PASS=1"
