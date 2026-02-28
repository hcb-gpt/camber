#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${ROOT_DIR}/scripts/load-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/scripts/load-env.sh"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

SUPABASE_BASE="${SUPABASE_URL:-https://rjhdwidddtfetbwqolof.supabase.co}"
REST_BASE="${SUPABASE_REST_URL:-${SUPABASE_BASE}/rest/v1}"
ANON_KEY="${SUPABASE_ANON_KEY:-${SUPABASE_SERVICE_ROLE_KEY:-}}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [[ -z "${ANON_KEY}" || -z "${SERVICE_KEY}" ]]; then
  echo "ERROR: SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY are required" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/artifacts/redline_pipeline_reconcile_harness/${STAMP}}"
mkdir -p "${OUT_DIR}"

header_value() {
  local header_file="$1"
  local key="$2"
  local key_lc
  key_lc="$(echo "${key}" | tr '[:upper:]' '[:lower:]')"
  awk -v k="${key_lc}" 'tolower($1)==k":"{print $2}' "${header_file}" | tr -d '\r'
}

echo "== redline pipeline reconcile harness =="
echo "SUPABASE_BASE=${SUPABASE_BASE}"
echo "OUT_DIR=${OUT_DIR}"

# 1) Get a real contact to anchor synthetic missing-call proof
curl -sS "${REST_BASE}/contacts?select=id,name,phone,phone_digits&phone_digits=not.is.null&order=updated_at.desc&limit=25" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" > "${OUT_DIR}/contact_seed.json"

CONTACT_ID="$(jq -r '[.[] | select((.phone // "") != "" and (.phone_digits // "") != "")][0].id // empty' "${OUT_DIR}/contact_seed.json")"
CONTACT_NAME="$(jq -r '[.[] | select((.phone // "") != "" and (.phone_digits // "") != "")][0].name // "Unknown Contact"' "${OUT_DIR}/contact_seed.json")"
CONTACT_PHONE="$(jq -r '[.[] | select((.phone // "") != "" and (.phone_digits // "") != "")][0].phone // empty' "${OUT_DIR}/contact_seed.json")"
if [[ -z "${CONTACT_ID}" || -z "${CONTACT_PHONE}" ]]; then
  echo "ERROR: could not find seed contact with phone" >&2
  exit 1
fi

# 2) Verify contract/request surfacing: redline-thread + assistant-context + assistant
H_THREAD_CONTACTS="${OUT_DIR}/thread_contacts.headers"
B_THREAD_CONTACTS="${OUT_DIR}/thread_contacts.body.json"
curl -sS -D "${H_THREAD_CONTACTS}" -o "${B_THREAD_CONTACTS}" \
  "${SUPABASE_BASE}/functions/v1/redline-thread?action=contacts&limit=5" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}"

THREAD_REQUEST_ID="$(header_value "${H_THREAD_CONTACTS}" "x-request-id")"
THREAD_CONTRACT_VERSION="$(header_value "${H_THREAD_CONTACTS}" "x-contract-version")"

H_CONTEXT="${OUT_DIR}/assistant_context.headers"
B_CONTEXT="${OUT_DIR}/assistant_context.body.json"
curl -sS -D "${H_CONTEXT}" -o "${B_CONTEXT}" \
  "${SUPABASE_BASE}/functions/v1/assistant-context" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}"

CONTEXT_REQUEST_ID="$(header_value "${H_CONTEXT}" "x-request-id")"
CONTEXT_CONTRACT_VERSION="$(header_value "${H_CONTEXT}" "x-contract-version")"

H_ASSISTANT="${OUT_DIR}/assistant.headers"
B_ASSISTANT="${OUT_DIR}/assistant.sse"
curl -sS -N -D "${H_ASSISTANT}" -o "${B_ASSISTANT}" \
  -X POST "${SUPABASE_BASE}/functions/v1/redline-assistant" \
  -H "Content-Type: application/json" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}" \
  -d '{"message":"What projects do you have"}'

ASSISTANT_REQUEST_ID="$(header_value "${H_ASSISTANT}" "x-request-id")"
ASSISTANT_CONTRACT_VERSION="$(header_value "${H_ASSISTANT}" "x-contract-version")"

# 3) Create synthetic missing call in calls_raw (no corresponding interactions row)
SYNTH_INTERACTION_ID="reconcile_test_${STAMP}"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${OUT_DIR}/synthetic_calls_raw_payload.json" <<EOF
[{
  "interaction_id": "${SYNTH_INTERACTION_ID}",
  "channel": "call",
  "thread_key": "reconcile_harness_${STAMP}",
  "direction": "inbound",
  "other_party_name": "${CONTACT_NAME}",
  "other_party_phone": "${CONTACT_PHONE}",
  "owner_name": "Harness",
  "owner_phone": "+17066889158",
  "event_at_utc": "${NOW_UTC}",
  "event_at_local": "${NOW_UTC}",
  "summary": "Synthetic harness call for missing-interaction reconciliation proof",
  "transcript": "Synthetic transcript for ${SYNTH_INTERACTION_ID}",
  "ingested_at_utc": "${NOW_UTC}",
  "is_shadow": false
}]
EOF

curl -sS -X POST "${REST_BASE}/calls_raw" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  --data @"${OUT_DIR}/synthetic_calls_raw_payload.json" > "${OUT_DIR}/calls_raw_insert_result.json"

curl -sS "${REST_BASE}/interactions?select=interaction_id&interaction_id=eq.${SYNTH_INTERACTION_ID}" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" > "${OUT_DIR}/interaction_before.json"
BEFORE_COUNT="$(jq 'length' "${OUT_DIR}/interaction_before.json")"

# 4) Run reconciliation
H_RECON="${OUT_DIR}/reconcile.headers"
B_RECON="${OUT_DIR}/reconcile.body.json"
curl -sS -D "${H_RECON}" -o "${B_RECON}" \
  -X POST "${SUPABASE_BASE}/functions/v1/reconcile-missing-interactions" \
  -H "Content-Type: application/json" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -d '{"limit":500,"dry_run":false}'

RECON_REQUEST_ID="$(header_value "${H_RECON}" "x-request-id")"
RECON_CONTRACT_VERSION="$(header_value "${H_RECON}" "x-contract-version")"
RECON_INSERTED_COUNT="$(jq -r '.inserted_count // 0' "${B_RECON}")"

curl -sS "${REST_BASE}/interactions?select=interaction_id,contact_id,contact_name,contact_phone,event_at_utc&interaction_id=eq.${SYNTH_INTERACTION_ID}" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" > "${OUT_DIR}/interaction_after.json"
AFTER_COUNT="$(jq 'length' "${OUT_DIR}/interaction_after.json")"
AFTER_CONTACT_ID="$(jq -r '.[0].contact_id // empty' "${OUT_DIR}/interaction_after.json")"

# 5) Verify reconciled interaction appears in redline-thread for contact
THREAD_MATCH_COUNT=0
THREAD_REQ_AFTER=""
if [[ -n "${AFTER_CONTACT_ID}" ]]; then
  H_THREAD_AFTER="${OUT_DIR}/thread_after.headers"
  B_THREAD_AFTER="${OUT_DIR}/thread_after.body.json"
  curl -sS -D "${H_THREAD_AFTER}" -o "${B_THREAD_AFTER}" \
    "${SUPABASE_BASE}/functions/v1/redline-thread?contact_id=${AFTER_CONTACT_ID}&limit=200" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${ANON_KEY}"
  THREAD_REQ_AFTER="$(header_value "${H_THREAD_AFTER}" "x-request-id")"
  THREAD_MATCH_COUNT="$(jq --arg iid "${SYNTH_INTERACTION_ID}" '[.thread[] | select(.interaction_id? == $iid)] | length' "${B_THREAD_AFTER}")"
fi

# 6) Post a debug issue report and verify table row exists
H_REPORT="${OUT_DIR}/report_issue.headers"
B_REPORT="${OUT_DIR}/report_issue.body.json"
curl -sS -D "${H_REPORT}" -o "${B_REPORT}" \
  -X POST "${SUPABASE_BASE}/functions/v1/report-data-issue" \
  -H "Content-Type: application/json" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}" \
  -d "$(jq -nc \
    --arg screen "pipeline_harness" \
    --arg cid "${CONTACT_ID}" \
    --arg phone "${CONTACT_PHONE}" \
    --arg iid "${SYNTH_INTERACTION_ID}" \
    --arg rid "${THREAD_REQ_AFTER:-${THREAD_REQUEST_ID}}" \
    --arg cv "${THREAD_CONTRACT_VERSION}" \
    '{screen:$screen,contact_id:$cid,phone:$phone,interaction_id:$iid,request_id:$rid,contract_version:$cv,note:"harness_smoke"}')"

REPORT_REQUEST_ID="$(header_value "${H_REPORT}" "x-request-id")"
REPORT_ID="$(jq -r '.report_id // empty' "${B_REPORT}")"
if [[ -n "${REPORT_ID}" ]]; then
  curl -sS "${REST_BASE}/redline_data_issue_reports?select=id,screen,contact_id,interaction_id,request_id,contract_version,created_at&id=eq.${REPORT_ID}" \
    -H "apikey: ${SERVICE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_KEY}" > "${OUT_DIR}/report_row.json"
else
  echo "[]" > "${OUT_DIR}/report_row.json"
fi
REPORT_ROW_COUNT="$(jq 'length' "${OUT_DIR}/report_row.json")"

# 7) Summary + pass/fail markers
CONTRACT_SURFACING_OK=0
if [[ -n "${THREAD_REQUEST_ID}" && -n "${THREAD_CONTRACT_VERSION}" && -n "${CONTEXT_REQUEST_ID}" && -n "${CONTEXT_CONTRACT_VERSION}" && -n "${ASSISTANT_REQUEST_ID}" && -n "${ASSISTANT_CONTRACT_VERSION}" ]]; then
  CONTRACT_SURFACING_OK=1
fi

RECON_OK=0
if [[ "${BEFORE_COUNT}" -eq 0 && "${AFTER_COUNT}" -ge 1 && "${THREAD_MATCH_COUNT}" -ge 1 ]]; then
  RECON_OK=1
fi

REPORT_OK=0
if [[ -n "${REPORT_ID}" && "${REPORT_ROW_COUNT}" -ge 1 ]]; then
  REPORT_OK=1
fi

cat > "${OUT_DIR}/summary.txt" <<EOF
out_dir=${OUT_DIR}
seed_contact_id=${CONTACT_ID}
seed_contact_phone=${CONTACT_PHONE}
synthetic_interaction_id=${SYNTH_INTERACTION_ID}

redline_thread_request_id=${THREAD_REQUEST_ID}
redline_thread_contract_version=${THREAD_CONTRACT_VERSION}
assistant_context_request_id=${CONTEXT_REQUEST_ID}
assistant_context_contract_version=${CONTEXT_CONTRACT_VERSION}
assistant_request_id=${ASSISTANT_REQUEST_ID}
assistant_contract_version=${ASSISTANT_CONTRACT_VERSION}

reconcile_request_id=${RECON_REQUEST_ID}
reconcile_contract_version=${RECON_CONTRACT_VERSION}
reconcile_inserted_count=${RECON_INSERTED_COUNT}
interaction_before_count=${BEFORE_COUNT}
interaction_after_count=${AFTER_COUNT}
thread_after_request_id=${THREAD_REQ_AFTER}
thread_match_count=${THREAD_MATCH_COUNT}

report_request_id=${REPORT_REQUEST_ID}
report_id=${REPORT_ID}
report_row_count=${REPORT_ROW_COUNT}

CHECK_CONTRACT_SURFACING=${CONTRACT_SURFACING_OK}
CHECK_RECONCILIATION=${RECON_OK}
CHECK_REPORT_ACTION=${REPORT_OK}
EOF

cat "${OUT_DIR}/summary.txt"

if [[ "${CONTRACT_SURFACING_OK}" -eq 1 && "${RECON_OK}" -eq 1 && "${REPORT_OK}" -eq 1 ]]; then
  echo "HARNESS_STATUS=PASS"
else
  echo "HARNESS_STATUS=FAIL"
  exit 1
fi
