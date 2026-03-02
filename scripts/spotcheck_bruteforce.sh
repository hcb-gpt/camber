#!/usr/bin/env bash
# spotcheck_bruteforce.sh
#
# Purpose:
#   Build a per-call evidence packet for independent "brute-force" agent review,
#   then compare that independent read against pipeline outputs.
#
# Usage:
#   ./scripts/spotcheck_bruteforce.sh <interaction_id>
#   ./scripts/spotcheck_bruteforce.sh --pick-latest
#   ./scripts/spotcheck_bruteforce.sh --pick-latest --output-dir /tmp/spotchecks

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

IID=""
PICK_LATEST=false
BASE_OUT_DIR="${ROOT_DIR}/artifacts/spotcheck_bruteforce"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pick-latest)
      PICK_LATEST=true
      shift
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
      echo "  $0 <interaction_id>"
      echo "  $0 --pick-latest"
      echo "  $0 --pick-latest --output-dir /tmp/spotchecks"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      exit 1
      ;;
    *)
      if [[ -n "${IID}" ]]; then
        echo "ERROR: multiple interaction IDs provided." >&2
        exit 1
      fi
      IID="$1"
      shift
      ;;
  esac
done

if [[ "${PICK_LATEST}" == "true" && -n "${IID}" ]]; then
  echo "ERROR: use either <interaction_id> or --pick-latest, not both." >&2
  exit 1
fi

sql_scalar() {
  local sql="$1"
  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -At -c "${sql}"
}

if [[ "${PICK_LATEST}" == "true" ]]; then
  IID="$(sql_scalar "SELECT interaction_id FROM calls_raw WHERE coalesce(is_shadow,false)=false ORDER BY ingested_at_utc DESC NULLS LAST LIMIT 1;")"
fi

if [[ -z "${IID}" ]]; then
  echo "ERROR: no interaction_id resolved." >&2
  exit 1
fi

if [[ ! "${IID}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: interaction_id has unsupported characters." >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${BASE_OUT_DIR}/${TS}_${IID}"
mkdir -p "${RUN_DIR}"

run_to_file() {
  local sql="$1"
  local out="$2"
  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -At -c "${sql}" > "${out}"
}

run_json_pretty_to_file() {
  local sql="$1"
  local out="$2"
  "${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -At -c "${sql}" > "${out}"
}

# 1) Transcript
run_to_file \
  "SELECT coalesce(transcript,'') FROM calls_raw WHERE interaction_id='${IID}' ORDER BY ingested_at_utc DESC NULLS LAST LIMIT 1;" \
  "${RUN_DIR}/transcript.txt"

# 2) Call + interaction metadata
run_json_pretty_to_file \
  "WITH c AS (
     SELECT interaction_id, channel, event_at_utc, ingested_at_utc, other_party_name, owner_name, summary, transcript
     FROM calls_raw
     WHERE interaction_id='${IID}'
     ORDER BY ingested_at_utc DESC NULLS LAST
     LIMIT 1
   ),
   i AS (
     SELECT interaction_id, contact_id, project_id, project_attribution_confidence, needs_review, review_reasons, attribution_lock, human_summary, candidate_projects, context_receipt
     FROM interactions
     WHERE interaction_id='${IID}'
     LIMIT 1
   ),
   p AS (
     SELECT id, name
     FROM projects
     WHERE id IN (
       SELECT project_id FROM i WHERE project_id IS NOT NULL
       UNION
       SELECT sa.project_id
       FROM span_attributions sa
       JOIN conversation_spans cs ON cs.id=sa.span_id
       WHERE cs.interaction_id='${IID}' AND sa.project_id IS NOT NULL
       UNION
       SELECT sa.applied_project_id
       FROM span_attributions sa
       JOIN conversation_spans cs ON cs.id=sa.span_id
       WHERE cs.interaction_id='${IID}' AND sa.applied_project_id IS NOT NULL
     )
   )
   SELECT jsonb_pretty(
     jsonb_build_object(
       'interaction_id','${IID}',
       'calls_raw', (SELECT to_jsonb(c) FROM c),
       'interaction_row', (SELECT to_jsonb(i) FROM i),
       'project_lookup', (SELECT coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) FROM p)
     )
   );" \
  "${RUN_DIR}/metadata.json"

# 3) Pipeline packet: latest spans + latest attribution per span + review queue rows + claims
run_json_pretty_to_file \
  "WITH lg AS (
     SELECT max(segment_generation) AS latest_segment_generation
     FROM conversation_spans
     WHERE interaction_id='${IID}'
   ),
   spans AS (
     SELECT
       cs.id AS span_id,
       cs.span_index,
       cs.segment_generation,
       cs.char_start,
       cs.char_end,
       cs.word_count,
       cs.segment_reason,
       left(coalesce(cs.transcript_segment,''), 600) AS segment_excerpt
     FROM conversation_spans cs
     JOIN lg ON cs.segment_generation = lg.latest_segment_generation
     WHERE cs.interaction_id='${IID}'
     ORDER BY cs.span_index
   ),
   latest_attr AS (
     SELECT DISTINCT ON (sa.span_id)
       sa.span_id,
       sa.decision,
       sa.confidence,
       sa.needs_review,
       sa.project_id,
       sa.applied_project_id,
       sa.attribution_source,
       sa.model_id,
       sa.prompt_version,
       sa.attributed_at,
       left(coalesce(sa.reasoning,''), 500) AS reasoning_excerpt,
       sa.anchors,
       sa.raw_response
     FROM span_attributions sa
     JOIN spans s ON s.span_id = sa.span_id
     ORDER BY sa.span_id, sa.attributed_at DESC
   ),
   rq AS (
     SELECT
       rq.id,
       rq.span_id,
       rq.status,
       rq.reason_codes,
       rq.resolution_action,
       rq.hit_count,
       rq.module,
       left(coalesce(rq.context_payload::text,''), 500) AS context_payload_excerpt
     FROM review_queue rq
     JOIN spans s ON s.span_id = rq.span_id
     ORDER BY rq.id DESC
   ),
   jc AS (
     SELECT
       claim_id,
       claim_type,
       left(coalesce(claim_text,''), 300) AS claim_text,
       speaker_label,
       claim_project_id,
       claim_project_confidence,
       attribution_confidence,
       epistemic_status,
       active,
       source_span_id
     FROM journal_claims
     WHERE call_id='${IID}'
     ORDER BY claim_project_confidence DESC NULLS LAST, attribution_confidence DESC NULLS LAST
     LIMIT 200
   )
   SELECT jsonb_pretty(
     jsonb_build_object(
       'latest_segment_generation', (SELECT latest_segment_generation FROM lg),
       'span_count', (SELECT count(*) FROM spans),
       'latest_spans', (SELECT coalesce(jsonb_agg(to_jsonb(spans)), '[]'::jsonb) FROM spans),
       'latest_attribution_per_span', (SELECT coalesce(jsonb_agg(to_jsonb(latest_attr)), '[]'::jsonb) FROM latest_attr),
       'review_queue_rows_for_latest_spans', (SELECT coalesce(jsonb_agg(to_jsonb(rq)), '[]'::jsonb) FROM rq),
       'journal_claims_for_call', (SELECT coalesce(jsonb_agg(to_jsonb(jc)), '[]'::jsonb) FROM jc)
     )
   );" \
  "${RUN_DIR}/pipeline_packet.json"

# 4) Coverage summary TSV for quick machine/manual checks
run_to_file \
  "WITH lg AS (
     SELECT max(segment_generation) AS g
     FROM conversation_spans
     WHERE interaction_id='${IID}'
   ),
   spans AS (
     SELECT id, span_index
     FROM conversation_spans, lg
     WHERE interaction_id='${IID}' AND segment_generation = lg.g
   ),
   a AS (SELECT DISTINCT span_id FROM span_attributions),
   rq AS (SELECT DISTINCT span_id FROM review_queue WHERE status='pending')
   SELECT
     s.span_index || E'\t' ||
     s.id || E'\t' ||
     CASE WHEN a.span_id IS NOT NULL THEN '1' ELSE '0' END || E'\t' ||
     CASE WHEN rq.span_id IS NOT NULL THEN '1' ELSE '0' END
   FROM spans s
   LEFT JOIN a ON a.span_id=s.id
   LEFT JOIN rq ON rq.span_id=s.id
   ORDER BY s.span_index;" \
  "${RUN_DIR}/coverage.tsv"

# 5) Analyst worksheet
cat > "${RUN_DIR}/agent_bruteforce_worksheet.md" <<EOF
# Agent Brute-Force Spotcheck

Interaction: \`${IID}\`
Generated: \`${TS}\`

## Step 1: Independent Read (No Pipeline Context)
- Read \`transcript.txt\` first.
- Decide:
  - Primary project:
  - Secondary project mentions:
  - Top commitments/promises:
  - Top risks/blockers:
  - Any ambiguous lines needing human review:

## Step 2: Pipeline Reality
- Open:
  - \`metadata.json\`
  - \`pipeline_packet.json\`
  - \`coverage.tsv\`
- Compare independent read vs pipeline output:
  - Project attribution agreement/disagreement
  - Missing spans / missing attribution rows
  - Missing or incorrect review_queue routing
  - Missing claims extraction

## Step 3: Score and Action
- Agreement score (0-100):
- Critical mismatches:
- Suggested fix lane:
  - segmentation
  - attribution
  - review routing
  - extraction
  - promotion/pointer

## Evidence Notes
- Add direct transcript line references for each mismatch.
EOF

SPAN_COUNT="$(awk 'END{print NR}' "${RUN_DIR}/coverage.tsv" 2>/dev/null || echo 0)"
ATTR_COUNT="$(awk -F'\t' '$3=="1"{c++} END{print c+0}' "${RUN_DIR}/coverage.tsv" 2>/dev/null || echo 0)"
PENDING_RQ_COUNT="$(awk -F'\t' '$4=="1"{c++} END{print c+0}' "${RUN_DIR}/coverage.tsv" 2>/dev/null || echo 0)"
CLAIM_COUNT="$(grep -c "\"claim_id\"" "${RUN_DIR}/pipeline_packet.json" 2>/dev/null || true)"
UNCOVERED_COUNT="$(awk -F'\t' '$3=="0" && $4=="0"{c++} END{print c+0}' "${RUN_DIR}/coverage.tsv" 2>/dev/null || echo 0)"
ATTRIBUTED_OR_REVIEWED_COUNT="$(awk -F'\t' '$3=="1" || $4=="1"{c++} END{print c+0}' "${RUN_DIR}/coverage.tsv" 2>/dev/null || echo 0)"

AUTO_STATUS="PASS"
if [[ "${UNCOVERED_COUNT}" -gt 0 ]]; then
  AUTO_STATUS="FAIL_SPAN_COVERAGE"
elif [[ "${CLAIM_COUNT}" -eq 0 && "${SPAN_COUNT}" -gt 0 ]]; then
  AUTO_STATUS="WARN_NO_CLAIMS"
fi

cat > "${RUN_DIR}/auto_findings.json" <<EOF
{
  "interaction_id": "${IID}",
  "latest_span_count": ${SPAN_COUNT},
  "latest_spans_with_attribution": ${ATTR_COUNT},
  "latest_spans_with_pending_review": ${PENDING_RQ_COUNT},
  "latest_spans_covered_attr_or_review": ${ATTRIBUTED_OR_REVIEWED_COUNT},
  "latest_spans_uncovered": ${UNCOVERED_COUNT},
  "journal_claim_count": ${CLAIM_COUNT},
  "auto_status": "${AUTO_STATUS}"
}
EOF

cat > "${RUN_DIR}/summary.txt" <<EOF
interaction_id=${IID}
latest_span_count=${SPAN_COUNT}
latest_spans_with_attribution=${ATTR_COUNT}
latest_spans_with_pending_review=${PENDING_RQ_COUNT}
latest_spans_covered_attr_or_review=${ATTRIBUTED_OR_REVIEWED_COUNT}
latest_spans_uncovered=${UNCOVERED_COUNT}
journal_claim_count=${CLAIM_COUNT}
auto_status=${AUTO_STATUS}
packet_dir=${RUN_DIR}
EOF

cat > "${RUN_DIR}/bruteforce_prompt.md" <<EOF
# Brute-Force Spotcheck Prompt

You are an independent QA analyst. Read the transcript and evaluate the pipeline outputs WITHOUT trusting model reasoning.

Inputs:
- transcript: \`transcript.txt\`
- pipeline packet: \`pipeline_packet.json\`
- interaction metadata: \`metadata.json\`
- coverage matrix: \`coverage.tsv\`

Required output format:
1) Primary project (best judgment) + confidence (0-1)
2) Secondary project mentions
3) Top commitments/promises (3-8 bullets with transcript evidence)
4) Top risks/blockers (2-6 bullets with transcript evidence)
5) Pipeline mismatches:
   - attribution mismatch
   - span coverage gap
   - review routing gap
   - extraction gap
6) Overall agreement score (0-100)
7) Action lane: segmentation | attribution | review routing | extraction | promotion/pointer

Hard rule:
- Every mismatch must cite direct transcript evidence (quote or line anchor).
EOF

echo "SPOTCHECK_PACKET_READY"
echo "interaction_id=${IID}"
echo "packet_dir=${RUN_DIR}"
echo "latest_span_count=${SPAN_COUNT}"
echo "latest_spans_with_attribution=${ATTR_COUNT}"
echo "latest_spans_with_pending_review=${PENDING_RQ_COUNT}"
echo "latest_spans_uncovered=${UNCOVERED_COUNT}"
echo "journal_claim_count=${CLAIM_COUNT}"
echo "auto_status=${AUTO_STATUS}"
