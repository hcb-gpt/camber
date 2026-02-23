#!/usr/bin/env bash
set -euo pipefail

# Process attribution_audit_queue -> audit-attribution-reviewer -> attribution_audit_ledger.
# This script claims pending queue rows, runs the reviewer on packet_json built from queue
# evidence pointers, persists verdicts into ledger, and marks queue rows done/error.
#
# Usage:
#   scripts/process_attribution_audit_queue.sh
#   scripts/process_attribution_audit_queue.sh --claim-limit 20 --worker-id dev5-queue-worker

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

CLAIM_LIMIT="${CLAIM_LIMIT:-50}"
WORKER_ID="${WORKER_ID:-dev5_queue_worker}"
REVIEWER_RUN_ID="${REVIEWER_RUN_ID:-queue_run_$(date -u +%Y%m%dT%H%M%SZ)}"
SOURCE_HEADER="${SOURCE_HEADER:-audit-attribution-test}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claim-limit)
      CLAIM_LIMIT="${2:-}"
      shift 2
      ;;
    --worker-id)
      WORKER_ID="${2:-}"
      shift 2
      ;;
    --reviewer-run-id)
      REVIEWER_RUN_ID="${2:-}"
      shift 2
      ;;
    --source-header)
      SOURCE_HEADER="${2:-}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  scripts/process_attribution_audit_queue.sh [options]

Options:
  --claim-limit <int>      Max pending rows to claim this run (default: 50)
  --worker-id <string>     Worker identity stamped in queue.claimed_by
  --reviewer-run-id <id>   reviewer_run_id written to attribution_audit_ledger
  --source-header <value>  X-Source header for reviewer invoke (default: audit-attribution-test)
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "${CLAIM_LIMIT}" =~ ^[0-9]+$ ]] || [[ "${CLAIM_LIMIT}" -lt 1 ]]; then
  echo "ERROR: --claim-limit must be a positive integer" >&2
  exit 1
fi

REVIEWER_RUN_ID_SQL="${REVIEWER_RUN_ID//\'/\'\'}"

if [[ -z "${DATABASE_URL:-}" || -z "${SUPABASE_URL:-}" || -z "${EDGE_SHARED_SECRET:-}" ]]; then
  echo "ERROR: DATABASE_URL, SUPABASE_URL, EDGE_SHARED_SECRET must be set." >&2
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

sql_at() {
  "${PSQL_BIN}" "${DATABASE_URL}" -X -At -v ON_ERROR_STOP=1 "$@"
}

mark_error() {
  local queue_id="$1"
  local err_text="$2"
  sql_at -v queue_id="${queue_id}" -v err_text="${err_text}" <<'SQL' >/dev/null
update public.attribution_audit_queue
set
  status = 'error',
  completed_at_utc = now(),
  error_text = left(:'err_text', 2000)
where id = :'queue_id'::uuid;
SQL
}

claim_rows() {
  sql_at -v claim_limit="${CLAIM_LIMIT}" -v worker_id="${WORKER_ID}" <<'SQL'
with picked as (
  select id
  from public.attribution_audit_queue
  where status = 'pending'
  order by created_at asc
  limit :'claim_limit'::int
  for update skip locked
),
claimed as (
  update public.attribution_audit_queue q
  set
    status = 'processing',
    claimed_by = :'worker_id',
    claimed_at_utc = now(),
    error_text = null
  where q.id in (select id from picked)
  returning q.id
)
select id
from claimed
order by id;
SQL
}

build_packet_json() {
  local queue_id="$1"
  sql_at -v queue_id="${queue_id}" <<'SQL'
with q as (
  select *
  from public.attribution_audit_queue
  where id = :'queue_id'::uuid
),
sa as (
  select
    q.id as queue_id,
    sa.id as span_attribution_id,
    coalesce(sa.applied_project_id, sa.project_id) as fallback_project_id,
    sa.decision as fallback_decision,
    sa.confidence as fallback_confidence,
    sa.evidence_tier as fallback_evidence_tier,
    sa.attribution_source as fallback_source
  from q
  left join public.span_attributions sa on sa.id = q.span_attribution_id
),
ee as (
  select
    q.id as queue_id,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'evidence_event_id', e.evidence_event_id,
          'occurred_at_utc', e.occurred_at_utc,
          'source_type', e.source_type,
          'source_id', e.source_id,
          'payload_ref', e.payload_ref,
          'integrity_hash', e.integrity_hash,
          'metadata', e.metadata
        )
      ) filter (where e.evidence_event_id is not null),
      '[]'::jsonb
    ) as evidence_events
  from q
  left join public.evidence_events e on e.evidence_event_id = q.evidence_event_id
  group by q.id
)
select jsonb_build_object(
  'interaction_id', q.interaction_id,
  'span_id', q.span_id,
  'span_attribution_id', q.span_attribution_id,
  'assigned_project_id', coalesce(q.assigned_project_id, sa.fallback_project_id),
  'assigned_decision', coalesce(sa.fallback_decision, 'assign'),
  'assigned_confidence', coalesce(q.assigned_confidence, sa.fallback_confidence),
  'assigned_evidence_tier', coalesce(q.evidence_tier, sa.fallback_evidence_tier),
  'attribution_source', coalesce(q.attribution_source, sa.fallback_source, 'manual'),
  'call_at_utc', q.t_call_utc,
  'asof_mode', coalesce(q.asof_mode, 'KNOWN_AS_OF'),
  'same_call_excluded', coalesce(q.same_call_excluded, true),
  'span_bounds', jsonb_build_object(
    'char_start', cs.char_start,
    'char_end', cs.char_end,
    'span_index', cs.span_index
  ),
  'transcript_segment', cs.transcript_segment,
  'evidence_event_id', q.evidence_event_id,
  'evidence_events', coalesce(ee.evidence_events, '[]'::jsonb),
  'claim_pointers',
    case
      when jsonb_typeof(q.anchors) = 'array' then q.anchors
      else '[]'::jsonb
    end,
  'as_of_project_context', '[]'::jsonb
)
from q
left join sa on sa.queue_id = q.id
left join ee on ee.queue_id = q.id
left join public.conversation_spans cs on cs.id = q.span_id;
SQL
}

insert_ledger_and_complete_queue() {
  local queue_id="$1"
  local packet_json="$2"
  local reviewer_provider="$3"
  local reviewer_model="$4"
  local reviewer_prompt_version="$5"
  local reviewer_run_id="$6"
  local verdict="$7"
  local top_candidates_json="$8"
  local failure_tags_json="$9"
  local missing_evidence_json="${10}"
  local leakage_violation="${11}"
  local pointer_quality_violation="${12}"
  local reviewer_temperature="${13}"
  local competing_margin="${14}"

  sql_at \
    -v queue_id="${queue_id}" \
    -v packet_json="${packet_json}" \
    -v reviewer_provider="${reviewer_provider}" \
    -v reviewer_model="${reviewer_model}" \
    -v reviewer_prompt_version="${reviewer_prompt_version}" \
    -v reviewer_run_id="${reviewer_run_id}" \
    -v verdict="${verdict}" \
    -v top_candidates_json="${top_candidates_json}" \
    -v failure_tags_json="${failure_tags_json}" \
    -v missing_evidence_json="${missing_evidence_json}" \
    -v leakage_violation="${leakage_violation}" \
    -v pointer_quality_violation="${pointer_quality_violation}" \
    -v reviewer_temperature="${reviewer_temperature}" \
    -v competing_margin="${competing_margin}" <<'SQL'
with q as (
  select
    q.*,
    sa.decision as sa_decision,
    sa.confidence as sa_confidence,
    sa.evidence_tier as sa_evidence_tier,
    sa.attribution_source as sa_source,
    coalesce(sa.applied_project_id, sa.project_id) as sa_project_id,
    cs.char_start,
    cs.char_end,
    cs.transcript_segment
  from public.attribution_audit_queue q
  left join public.span_attributions sa on sa.id = q.span_attribution_id
  left join public.conversation_spans cs on cs.id = q.span_id
  where q.id = :'queue_id'::uuid
),
normalized as (
  select
    q.id as queue_id,
    q.span_attribution_id,
    q.span_id,
    q.interaction_id,
    coalesce(q.assigned_project_id, q.sa_project_id) as assigned_project_id,
    case
      when coalesce(q.sa_decision, '') in ('assign', 'review', 'none') then q.sa_decision
      when coalesce(q.assigned_project_id, q.sa_project_id) is null then 'review'
      else 'assign'
    end as assigned_decision,
    case
      when coalesce(q.sa_decision, case when coalesce(q.assigned_project_id, q.sa_project_id) is null then 'review' else 'assign' end) = 'assign'
        then least(1::numeric, greatest(0::numeric, coalesce(q.assigned_confidence, q.sa_confidence, 0.5::numeric)))
      else coalesce(q.assigned_confidence, q.sa_confidence)
    end as assigned_confidence,
    coalesce(q.attribution_source, q.sa_source, 'manual') as attribution_source,
    coalesce(q.evidence_tier::int, q.sa_evidence_tier::int) as evidence_tier,
    coalesce(q.t_call_utc, now()) as t_call_utc,
    'KNOWN_AS_OF'::text as asof_mode,
    true as same_call_excluded,
    case
      when q.evidence_event_id is null then '{}'::uuid[]
      else array[q.evidence_event_id]::uuid[]
    end as evidence_event_ids,
    q.char_start as span_char_start,
    q.char_end as span_char_end,
    md5(coalesce(q.transcript_segment, '')) as transcript_span_hash,
    (:'packet_json')::jsonb as packet_json,
    md5((:'packet_json')::text) as packet_hash,
    :'reviewer_provider'::text as reviewer_provider,
    :'reviewer_model'::text as reviewer_model,
    :'reviewer_prompt_version'::text as reviewer_prompt_version,
    nullif(:'reviewer_temperature', '')::numeric as reviewer_temperature,
    :'reviewer_run_id'::text as reviewer_run_id,
    upper(:'verdict')::text as verdict_raw,
    coalesce((:'top_candidates_json')::jsonb, '[]'::jsonb) as top_candidates_raw,
    nullif(:'competing_margin', '')::numeric as competing_margin,
    coalesce(array(select jsonb_array_elements_text((:'failure_tags_json')::jsonb)), '{}'::text[]) as failure_tags_raw,
    coalesce(array(select jsonb_array_elements_text((:'missing_evidence_json')::jsonb)), '{}'::text[]) as missing_evidence_raw,
    coalesce(:'leakage_violation'::boolean, false) as leakage_violation,
    coalesce(:'pointer_quality_violation'::boolean, false) as pointer_quality_violation
  from q
),
allowed as (
  select unnest(array[
    'missing_alias_anchor',
    'wrong_vendor_binding',
    'multi_project_span_ambiguity',
    'known_asof_violation',
    'same_call_leakage',
    'insufficient_provenance_pointer_quality',
    'competing_candidate_too_close',
    'location_anchor_overweight',
    'floater_confusion',
    'timeline_anchor_missing',
    'doc_anchor_missing',
    'matched_terms_spurious'
  ]::text[]) as tag
),
prepared as (
  select
    n.*,
    md5(concat_ws('|', n.span_attribution_id::text, n.reviewer_model, n.reviewer_prompt_version, n.packet_hash)) as dedupe_key,
    case
      when n.verdict_raw in ('MATCH', 'MISMATCH', 'INSUFFICIENT') then n.verdict_raw
      else 'INSUFFICIENT'
    end as safe_verdict,
    coalesce(
      (
        select array_agg(t)
        from (
          select distinct t
          from unnest(n.failure_tags_raw) t
          join allowed a on a.tag = t
        ) s
      ),
      '{}'::text[]
    ) as failure_tags_allowed
  from normalized n
),
final as (
  select
    p.*,
    case
      when p.safe_verdict = 'MISMATCH'
       and (jsonb_typeof(p.top_candidates_raw) <> 'array' or jsonb_array_length(p.top_candidates_raw) = 0)
        then jsonb_build_array(
          jsonb_build_object(
            'project_id', p.assigned_project_id,
            'confidence', coalesce(p.assigned_confidence, 0.5),
            'anchor_rationale', 'fallback_candidate'
          )
        )
      when jsonb_typeof(p.top_candidates_raw) = 'array' then p.top_candidates_raw
      else '[]'::jsonb
    end as top_candidates_safe,
    case
      when cardinality(p.failure_tags_allowed) = 0 and p.safe_verdict = 'MISMATCH'
        then array['wrong_vendor_binding']::text[]
      when cardinality(p.failure_tags_allowed) = 0 and p.safe_verdict = 'INSUFFICIENT'
        then array['insufficient_provenance_pointer_quality']::text[]
      else p.failure_tags_allowed
    end as failure_tags_safe,
    case
      when cardinality(p.missing_evidence_raw) = 0 and p.safe_verdict <> 'MATCH'
        then array['reviewer_disagrees_assignment']::text[]
      else p.missing_evidence_raw
    end as missing_evidence_safe,
    case
      when cardinality(p.evidence_event_ids) = 0 then true
      else p.pointer_quality_violation
    end as pointer_quality_safe
  from prepared p
),
upserted as (
  insert into public.attribution_audit_ledger (
    dedupe_key,
    span_attribution_id,
    span_id,
    interaction_id,
    assigned_project_id,
    assigned_decision,
    assigned_confidence,
    attribution_source,
    evidence_tier,
    t_call_utc,
    asof_mode,
    same_call_excluded,
    evidence_event_ids,
    span_char_start,
    span_char_end,
    transcript_span_hash,
    packet_json,
    packet_hash,
    reviewer_provider,
    reviewer_model,
    reviewer_prompt_version,
    reviewer_temperature,
    reviewer_run_id,
    verdict,
    top_candidates,
    competing_margin,
    failure_tags,
    missing_evidence,
    leakage_violation,
    pointer_quality_violation
  )
  select
    f.dedupe_key,
    f.span_attribution_id,
    f.span_id,
    f.interaction_id,
    f.assigned_project_id,
    f.assigned_decision,
    f.assigned_confidence,
    f.attribution_source,
    f.evidence_tier,
    f.t_call_utc,
    f.asof_mode,
    f.same_call_excluded,
    f.evidence_event_ids,
    f.span_char_start,
    f.span_char_end,
    f.transcript_span_hash,
    f.packet_json,
    f.packet_hash,
    f.reviewer_provider,
    f.reviewer_model,
    f.reviewer_prompt_version,
    f.reviewer_temperature,
    f.reviewer_run_id,
    f.safe_verdict,
    f.top_candidates_safe,
    f.competing_margin,
    f.failure_tags_safe,
    f.missing_evidence_safe,
    f.leakage_violation,
    f.pointer_quality_safe
  from final f
  on conflict (dedupe_key) do update
    set
      hit_count = public.attribution_audit_ledger.hit_count + 1,
      last_seen_at_utc = now(),
      reviewer_run_id = excluded.reviewer_run_id,
      reviewer_temperature = excluded.reviewer_temperature,
      verdict = excluded.verdict,
      top_candidates = excluded.top_candidates,
      competing_margin = excluded.competing_margin,
      failure_tags = excluded.failure_tags,
      missing_evidence = excluded.missing_evidence,
      leakage_violation = excluded.leakage_violation,
      pointer_quality_violation = excluded.pointer_quality_violation
  returning
    id as ledger_id,
    dedupe_key,
    hit_count,
    verdict,
    failure_tags,
    top_candidates
),
queue_done as (
  update public.attribution_audit_queue q
  set
    status = 'done',
    completed_at_utc = now(),
    error_text = null
  where q.id = :'queue_id'::uuid
  returning q.id as queue_id
)
select
  q.queue_id,
  u.ledger_id,
  u.dedupe_key,
  u.hit_count,
  u.verdict,
  u.failure_tags,
  u.top_candidates
from queue_done q
cross join upserted u;
SQL
}

normalize_failure_tags_json() {
  local response_file="$1"
  jq -c '
    def allowed:
      [
        "missing_alias_anchor",
        "wrong_vendor_binding",
        "multi_project_span_ambiguity",
        "known_asof_violation",
        "same_call_leakage",
        "insufficient_provenance_pointer_quality",
        "competing_candidate_too_close",
        "location_anchor_overweight",
        "floater_confusion",
        "timeline_anchor_missing",
        "doc_anchor_missing",
        "matched_terms_spurious"
      ];
    def norm:
      ascii_downcase
      | gsub("[^a-z0-9_]+"; "_")
      | gsub("_+"; "_")
      | sub("^_+"; "")
      | sub("_+$"; "");
    def map_tag($t):
      if (allowed | index($t)) != null then $t
      elif ($t | test("same_call|leakage")) then "same_call_leakage"
      elif ($t | test("assignment_disagreement|mismatch|wrong_project|wrong_vendor")) then "wrong_vendor_binding"
      elif ($t | test("multi|ambigu|candidate")) then "multi_project_span_ambiguity"
      elif ($t | test("known_asof|asof|future|timeline")) then "known_asof_violation"
      elif ($t | test("pointer|provenance|insufficient_context|context_missing|missing_evidence")) then "insufficient_provenance_pointer_quality"
      elif ($t | test("alias")) then "missing_alias_anchor"
      elif ($t | test("location|address")) then "location_anchor_overweight"
      elif ($t | test("doc|document")) then "doc_anchor_missing"
      elif ($t | test("matched_terms|spurious")) then "matched_terms_spurious"
      elif ($t | test("floater")) then "floater_confusion"
      else empty
      end;
    [
      (.reviewer_output.failure_mode_tags // [])[]
      | tostring
      | norm as $t
      | map_tag($t)
    ] | unique
  ' "${response_file}"
}

normalize_missing_evidence_json() {
  local response_file="$1"
  jq -c '
    [
      (.reviewer_output.missing_evidence // [])[]
      | tostring
      | ascii_downcase
      | gsub("[^a-z0-9_]+"; "_")
      | gsub("_+"; "_")
      | sub("^_+"; "")
      | sub("_+$"; "")
      | select(length > 0)
    ] | unique | .[:24]
  ' "${response_file}"
}

echo "REVIEWER_RUN_ID=${REVIEWER_RUN_ID}"
echo "WORKER_ID=${WORKER_ID}"

CLAIMED_IDS=()
while IFS= read -r line; do
  if [[ -n "${line}" ]]; then
    CLAIMED_IDS+=("${line}")
  fi
done < <(claim_rows)

if [[ "${#CLAIMED_IDS[@]}" -eq 0 ]]; then
  pending_now="$(sql_at -c "select count(*) from public.attribution_audit_queue where status='pending';")"
  echo "CLAIMED_COUNT=0"
  echo "PENDING_COUNT=${pending_now}"
  exit 0
fi

RESULTS_FILE="$(mktemp)"
ERRORS_FILE="$(mktemp)"

echo "CLAIMED_COUNT=${#CLAIMED_IDS[@]}"

for queue_id in "${CLAIMED_IDS[@]}"; do
  packet_json="$(build_packet_json "${queue_id}" || true)"
  if [[ -z "${packet_json}" ]]; then
    mark_error "${queue_id}" "packet_build_failed"
    echo "${queue_id}\tpacket_build_failed" >> "${ERRORS_FILE}"
    continue
  fi

  if ! jq -e . >/dev/null <<<"${packet_json}"; then
    mark_error "${queue_id}" "packet_json_invalid"
    echo "${queue_id}\tpacket_json_invalid" >> "${ERRORS_FILE}"
    continue
  fi

  req_file="$(mktemp)"
  resp_file="$(mktemp)"
  jq -cn --argjson packet "${packet_json}" '{packet_json: $packet}' > "${req_file}"

  http_code="$(
    curl -sS -o "${resp_file}" -w '%{http_code}' \
      -X POST "${SUPABASE_URL}/functions/v1/audit-attribution-reviewer" \
      -H "Content-Type: application/json" \
      -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
      -H "X-Source: ${SOURCE_HEADER}" \
      -d @"${req_file}"
  )"

  rm -f "${req_file}"

  if [[ "${http_code}" != "200" ]]; then
    err="reviewer_http_${http_code}"
    body="$(tr '\n' ' ' < "${resp_file}" | head -c 900)"
    mark_error "${queue_id}" "${err}: ${body}"
    echo "${queue_id}\t${err}" >> "${ERRORS_FILE}"
    rm -f "${resp_file}"
    continue
  fi

  if ! jq -e '.ok == true and (.reviewer_output.verdict | type == "string")' "${resp_file}" >/dev/null; then
    body="$(tr '\n' ' ' < "${resp_file}" | head -c 900)"
    mark_error "${queue_id}" "reviewer_response_invalid: ${body}"
    echo "${queue_id}\treviewer_response_invalid" >> "${ERRORS_FILE}"
    rm -f "${resp_file}"
    continue
  fi

  verdict="$(jq -r '.reviewer_output.verdict // "INSUFFICIENT"' "${resp_file}" | tr '[:lower:]' '[:upper:]')"
  if [[ "${verdict}" != "MATCH" && "${verdict}" != "MISMATCH" && "${verdict}" != "INSUFFICIENT" ]]; then
    verdict="INSUFFICIENT"
  fi

  reviewer_provider="anthropic"
  reviewer_model="$(jq -r '.model_id // "unknown_model"' "${resp_file}")"
  reviewer_prompt_version="$(jq -r '.prompt_version // "unknown_prompt"' "${resp_file}")"
  top_candidates_json="$(jq -c '.reviewer_output.top_candidates // []' "${resp_file}")"
  failure_tags_json="$(normalize_failure_tags_json "${resp_file}")"
  missing_evidence_json="$(normalize_missing_evidence_json "${resp_file}")"
  leakage_violation="$(
    jq -r '
      [(.reviewer_output.failure_mode_tags // [])[] | tostring | ascii_downcase]
      | any(test("same_call|leakage|known_asof|asof|future"))
    ' "${resp_file}"
  )"
  pointer_quality_violation="$(
    jq -r '
      ((.reviewer_output.failure_mode_tags // []) + (.reviewer_output.missing_evidence // []))
      | map(tostring | ascii_downcase)
      | any(test("pointer|provenance|insufficient_context"))
    ' "${resp_file}"
  )"

  if [[ -z "${failure_tags_json}" ]]; then
    failure_tags_json='[]'
  fi
  if [[ -z "${missing_evidence_json}" ]]; then
    missing_evidence_json='[]'
  fi
  if [[ -z "${top_candidates_json}" ]]; then
    top_candidates_json='[]'
  fi

  if ! insert_result="$(
    insert_ledger_and_complete_queue \
      "${queue_id}" \
      "${packet_json}" \
      "${reviewer_provider}" \
      "${reviewer_model}" \
      "${reviewer_prompt_version}" \
      "${REVIEWER_RUN_ID}" \
      "${verdict}" \
      "${top_candidates_json}" \
      "${failure_tags_json}" \
      "${missing_evidence_json}" \
      "${leakage_violation}" \
      "${pointer_quality_violation}" \
      "" \
      ""
  )"; then
    mark_error "${queue_id}" "ledger_insert_failed"
    echo "${queue_id}\tledger_insert_failed" >> "${ERRORS_FILE}"
    rm -f "${resp_file}"
    continue
  fi

  echo "${insert_result}" >> "${RESULTS_FILE}"
  rm -f "${resp_file}"
done

PENDING_COUNT="$(sql_at -c "select count(*) from public.attribution_audit_queue where status='pending';")"
PROCESSING_COUNT="$(sql_at -c "select count(*) from public.attribution_audit_queue where status='processing';")"
DONE_COUNT="$(sql_at -c "select count(*) from public.attribution_audit_queue where status='done';")"
ERROR_COUNT="$(sql_at -c "select count(*) from public.attribution_audit_queue where status='error';")"
RUN_LEDGER_COUNT="$(
  sql_at -c "
    select count(*)
    from public.attribution_audit_ledger
    where reviewer_run_id = '${REVIEWER_RUN_ID_SQL}';
  "
)"
SAMPLE_LEDGER_JSON="$(
  sql_at -c "
    select jsonb_build_object(
      'ledger_id', id,
      'verdict', verdict,
      'failure_tags', failure_tags,
      'top_candidates', top_candidates
    )
    from public.attribution_audit_ledger
    where reviewer_run_id = '${REVIEWER_RUN_ID_SQL}'
    order by created_at desc
    limit 1;
  "
)"

echo "PENDING_COUNT=${PENDING_COUNT}"
echo "PROCESSING_COUNT=${PROCESSING_COUNT}"
echo "DONE_COUNT=${DONE_COUNT}"
echo "ERROR_COUNT=${ERROR_COUNT}"
echo "RUN_LEDGER_COUNT=${RUN_LEDGER_COUNT}"
echo "SAMPLE_LEDGER_JSON=${SAMPLE_LEDGER_JSON}"
echo "RESULT_ROWS_FILE=${RESULTS_FILE}"
echo "ERROR_ROWS_FILE=${ERRORS_FILE}"
