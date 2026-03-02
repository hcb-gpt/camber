#!/usr/bin/env bash
# spotcheck_bruteforce_batch.sh
#
# Runs N brute-force spotcheck packets and writes a consolidated report.
#
# Usage:
#   ./scripts/spotcheck_bruteforce_batch.sh
#   ./scripts/spotcheck_bruteforce_batch.sh --count 5 --sample random
#   ./scripts/spotcheck_bruteforce_batch.sh --calls cll_A,cll_B

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

PSQL_BIN="${PSQL_PATH:-psql}"
if [[ ! -x "${PSQL_BIN}" ]]; then
  if command -v "${PSQL_BIN}" >/dev/null 2>&1; then
    PSQL_BIN="$(command -v "${PSQL_BIN}")"
  else
    echo "ERROR: psql not found. Set PSQL_PATH or install psql." >&2
    exit 1
  fi
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL is not set after env load." >&2
  exit 1
fi

COUNT=3
SAMPLE_MODE="latest" # latest | random
MIN_TRANSCRIPT_CHARS=2000
CALLS_CSV=""
BASE_OUT_DIR="${ROOT_DIR}/artifacts/spotcheck_bruteforce_batch"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --count requires a numeric value." >&2
        exit 2
      fi
      COUNT="${2:-}"
      shift 2
      ;;
    --sample)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --sample requires 'latest' or 'random'." >&2
        exit 2
      fi
      SAMPLE_MODE="${2:-}"
      shift 2
      ;;
    --min-transcript-chars)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --min-transcript-chars requires a numeric value." >&2
        exit 2
      fi
      MIN_TRANSCRIPT_CHARS="${2:-}"
      shift 2
      ;;
    --calls)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --calls requires a comma-separated interaction_id list." >&2
        exit 2
      fi
      CALLS_CSV="${2:-}"
      shift 2
      ;;
    --output-dir)
      if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
        echo "ERROR: --output-dir requires a path." >&2
        exit 2
      fi
      BASE_OUT_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      echo "Usage:"
      echo "  $0 [--count N] [--sample latest|random] [--min-transcript-chars N]"
      echo "  $0 --calls cll_A,cll_B"
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

if [[ "${SAMPLE_MODE}" != "latest" && "${SAMPLE_MODE}" != "random" ]]; then
  echo "ERROR: --sample must be 'latest' or 'random'." >&2
  exit 1
fi

if [[ ! "${COUNT}" =~ ^[0-9]+$ ]] || (( COUNT <= 0 )); then
  echo "ERROR: --count must be a positive integer." >&2
  exit 2
fi

if [[ ! "${MIN_TRANSCRIPT_CHARS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --min-transcript-chars must be a non-negative integer." >&2
  exit 2
fi

if [[ -n "${CALLS_CSV}" && "${SAMPLE_MODE}" == "random" ]]; then
  echo "ERROR: use either --calls or --sample random, not both." >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${BASE_OUT_DIR}/${TS}"
mkdir -p "${RUN_DIR}"

CALL_LIST_FILE="${RUN_DIR}/calls.txt"

if [[ -n "${CALLS_CSV}" ]]; then
  printf "%s\n" "${CALLS_CSV//,/ }" | tr ' ' '\n' | sed '/^$/d' > "${CALL_LIST_FILE}"
else
  ORDER_CLAUSE="ORDER BY last_ingested_at DESC NULLS LAST"
  if [[ "${SAMPLE_MODE}" == "random" ]]; then
    ORDER_CLAUSE="ORDER BY random()"
  fi

  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -At -c "
    WITH eligible_calls AS (
      SELECT
        cr.interaction_id,
        max(cr.ingested_at_utc) AS last_ingested_at
      FROM calls_raw cr
      WHERE coalesce(cr.is_shadow,false)=false
        AND char_length(coalesce(cr.transcript,'')) >= ${MIN_TRANSCRIPT_CHARS}
        AND cr.interaction_id IS NOT NULL
      GROUP BY cr.interaction_id
    )
    SELECT interaction_id
    FROM eligible_calls
    ${ORDER_CLAUSE}
    LIMIT ${COUNT};
  " > "${CALL_LIST_FILE}"
fi

if [[ ! -s "${CALL_LIST_FILE}" ]]; then
  echo "ERROR: no calls selected for batch spotcheck." >&2
  exit 1
fi

RESULTS_TSV="${RUN_DIR}/results.tsv"
: > "${RESULTS_TSV}"

while IFS= read -r iid; do
  [[ -z "${iid}" ]] && continue
  if [[ ! "${iid}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "skip_invalid_iid=${iid}" >> "${RUN_DIR}/warnings.log"
    continue
  fi

  OUT="$("${ROOT_DIR}/scripts/spotcheck_bruteforce.sh" "${iid}")"
  PACKET_DIR="$(printf "%s\n" "${OUT}" | awk -F= '/^packet_dir=/{print $2}')"
  if [[ -z "${PACKET_DIR}" || ! -f "${PACKET_DIR}/summary.txt" ]]; then
    echo "spotcheck_failed_iid=${iid}" >> "${RUN_DIR}/warnings.log"
    continue
  fi

  # shellcheck disable=SC1090
  source "${PACKET_DIR}/summary.txt"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${interaction_id}" \
    "${latest_span_count}" \
    "${latest_spans_with_attribution}" \
    "${latest_spans_with_pending_review}" \
    "${latest_spans_uncovered}" \
    "${journal_claim_count}" \
    "${auto_status}" >> "${RESULTS_TSV}"
done < "${CALL_LIST_FILE}"

REPORT_MD="${RUN_DIR}/batch_report.md"
TOTAL_CALLS="$(wc -l < "${RESULTS_TSV}" | tr -d ' ')"
FAIL_COUNT="$(awk -F'\t' '$7=="FAIL_SPAN_COVERAGE"{c++} END{print c+0}' "${RESULTS_TSV}")"
WARN_COUNT="$(awk -F'\t' '$7=="WARN_NO_CLAIMS"{c++} END{print c+0}' "${RESULTS_TSV}")"
PASS_COUNT="$(awk -F'\t' '$7=="PASS"{c++} END{print c+0}' "${RESULTS_TSV}")"

{
  echo "# Brute-Force Batch Spotcheck"
  echo
  echo "- Run UTC: \`${TS}\`"
  echo "- Sample mode: \`${SAMPLE_MODE}\`"
  echo "- Min transcript chars: \`${MIN_TRANSCRIPT_CHARS}\`"
  echo "- Calls analyzed: \`${TOTAL_CALLS}\`"
  echo "- PASS: \`${PASS_COUNT}\` | WARN: \`${WARN_COUNT}\` | FAIL: \`${FAIL_COUNT}\`"
  echo
  echo "| interaction_id | spans | attr_spans | pending_review_spans | uncovered_spans | journal_claims | status |"
  echo "|---|---:|---:|---:|---:|---:|---|"
  awk -F'\t' '{printf("| `%s` | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7)}' "${RESULTS_TSV}"
  echo
  echo "## Follow-up Rule"
  echo "- Any row with \`FAIL_SPAN_COVERAGE\` is a triage candidate for attribution/review routing fixes."
  echo "- Any row with \`WARN_NO_CLAIMS\` is a candidate for extraction continuity checks."
  echo
  echo "## Packet Paths"
  echo "- Individual packets live under: \`${ROOT_DIR}/artifacts/spotcheck_bruteforce/\`"
} > "${REPORT_MD}"

echo "SPOTCHECK_BATCH_READY"
echo "run_dir=${RUN_DIR}"
echo "report=${REPORT_MD}"
echo "results=${RESULTS_TSV}"
echo "calls_analyzed=${TOTAL_CALLS}"
echo "pass=${PASS_COUNT}"
echo "warn=${WARN_COUNT}"
echo "fail=${FAIL_COUNT}"
