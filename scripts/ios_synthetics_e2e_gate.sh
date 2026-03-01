#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNTHETICS_SCRIPT="${ROOT_DIR}/scripts/synthetics/run_synthetics.sh"
SCENARIOS_FILE="${ROOT_DIR}/scripts/synthetics/scenarios.json"
IOS_SMOKE_SCRIPT="${ROOT_DIR}/scripts/ios_simulator_smoke_drive.sh"

SCENARIO_COUNT=5
POLL_TIMEOUT_SECONDS=180
POLL_INTERVAL_SECONDS=10
CUTOFF_DATE_UTC="2026-02-07T00:00:00Z"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ROOT_DIR}/artifacts/ios_synthetics_e2e/${RUN_ID}"
SYNTH_OUT_DIR="${OUT_DIR}/synthetics"
POLL_OUT_DIR="${OUT_DIR}/poll"

usage() {
  cat <<'EOF'
Usage: scripts/ios_synthetics_e2e_gate.sh [options]

Run a full E2E gate:
1) Live synthetics pack (fixed scenario subset)
2) Poll DB for decision/review readiness
3) iOS simulator smoke with synthetic interaction targeting
4) Freshness/assertion checks + proof summary

Options:
  --scenario-count <n>      Number of scenarios to run from scenarios.json (default: 5)
  --poll-timeout <seconds>  Max readiness polling duration (default: 180)
  --poll-interval <seconds> Poll interval (default: 10)
  --cutoff-utc <iso8601>    Triage freshness cutoff (default: 2026-02-07T00:00:00Z)
  --help, -h                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario-count)
      SCENARIO_COUNT="${2:-}"
      shift 2
      ;;
    --poll-timeout)
      POLL_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL_SECONDS="${2:-}"
      shift 2
      ;;
    --cutoff-utc)
      CUTOFF_DATE_UTC="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 2
fi

if [[ -f "${HOME}/.camber/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.camber/credentials.env"
fi

if [[ -f "${ROOT_DIR}/scripts/load-env.sh" ]]; then
  # Source with nounset disabled because load-env.sh uses unguarded vars.
  set +u
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null 2>&1 || true
  set -u
fi

for var in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY EDGE_SHARED_SECRET; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: missing required env var: ${var}" >&2
    exit 2
  fi
done

if [[ ! -x "${SYNTHETICS_SCRIPT}" ]]; then
  echo "ERROR: missing executable synthetics runner: ${SYNTHETICS_SCRIPT}" >&2
  exit 2
fi

if [[ ! -x "${IOS_SMOKE_SCRIPT}" ]]; then
  echo "ERROR: missing executable iOS smoke runner: ${IOS_SMOKE_SCRIPT}" >&2
  exit 2
fi

if [[ ! -f "${SCENARIOS_FILE}" ]]; then
  echo "ERROR: missing scenarios file: ${SCENARIOS_FILE}" >&2
  exit 2
fi

mkdir -p "${SYNTH_OUT_DIR}" "${POLL_OUT_DIR}"

RUN_TS="$(date +%s)"

scenario_id_to_interaction_id() {
  local scenario_id="$1"
  local normalized
  normalized="$(
    echo "${scenario_id}" \
      | tr '[:lower:]' '[:upper:]' \
      | tr -cd 'A-Z0-9_' \
      | cut -c 1-20
  )"
  echo "cll_SYNTH_${normalized}_${RUN_TS}"
}

scenario_ids=()
while IFS= read -r sid; do
  [[ -z "${sid}" ]] && continue
  scenario_ids+=("${sid}")
done < <(jq -r ".[0:${SCENARIO_COUNT}] | .[].scenario_id" "${SCENARIOS_FILE}")

if [[ ${#scenario_ids[@]} -eq 0 ]]; then
  echo "ERROR: no scenarios selected from ${SCENARIOS_FILE}" >&2
  exit 2
fi

interaction_ids=()
synthetics_fail_count=0

echo "SYNTHETICS_RUN_ID=${RUN_ID}"
echo "SYNTHETICS_SCENARIO_COUNT=${#scenario_ids[@]}"

printf "scenario_id,interaction_id,exit_code\n" > "${SYNTH_OUT_DIR}/scenario_results.csv"

for sid in "${scenario_ids[@]}"; do
  iid="$(scenario_id_to_interaction_id "${sid}")"
  interaction_ids+=("${iid}")
  out_file="${SYNTH_OUT_DIR}/${sid}.log"

  echo "[e2e] run_synthetics scenario=${sid} interaction_id=${iid}"
  set +e
  bash "${SYNTHETICS_SCRIPT}" --scenario "${sid}" --timestamp "${RUN_TS}" > "${out_file}" 2>&1
  rc=$?
  set -e

  printf "%s,%s,%s\n" "${sid}" "${iid}" "${rc}" >> "${SYNTH_OUT_DIR}/scenario_results.csv"
  if [[ ${rc} -ne 0 ]]; then
    synthetics_fail_count=$((synthetics_fail_count + 1))
  fi
done

check_interaction_ready() {
  local interaction_id="$1"
  local out_file="$2"
  local spans_json span_ids_csv span_count attrib_json decision_count rq_json rq_count newest_review_event

  spans_json="$(
    curl -sf \
      "${SUPABASE_URL}/rest/v1/conversation_spans?interaction_id=eq.${interaction_id}&select=id,interaction_id" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      || echo "[]"
  )"

  span_count="$(echo "${spans_json}" | jq 'length' 2>/dev/null || echo 0)"
  span_ids_csv=""
  if [[ "${span_count}" -gt 0 ]]; then
    span_ids_csv="$(echo "${spans_json}" | jq -r '.[].id' | paste -sd ',' -)"
  fi

  attrib_json="[]"
  decision_count=0
  if [[ -n "${span_ids_csv}" ]]; then
    attrib_json="$(
      curl -sf \
        "${SUPABASE_URL}/rest/v1/span_attributions?span_id=in.(${span_ids_csv})&select=span_id,decision,project_id,applied_project_id,confidence,attributed_at" \
        -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
        || echo "[]"
    )"
    decision_count="$(echo "${attrib_json}" | jq '[.[] | select(.decision != null)] | length' 2>/dev/null || echo 0)"
  fi

  rq_json="$(
    curl -sf \
      "${SUPABASE_URL}/rest/v1/review_queue?interaction_id=eq.${interaction_id}&select=id,status,event_at_utc,created_at,interaction_id&order=event_at_utc.desc&limit=5" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      || echo "[]"
  )"
  rq_count="$(echo "${rq_json}" | jq 'length' 2>/dev/null || echo 0)"
  newest_review_event="$(echo "${rq_json}" | jq -r '.[0].event_at_utc // .[0].created_at // empty' 2>/dev/null || true)"

  ready="no"
  if [[ "${decision_count}" -gt 0 || "${rq_count}" -gt 0 ]]; then
    ready="yes"
  fi

  jq -n \
    --arg interaction_id "${interaction_id}" \
    --arg ready "${ready}" \
    --argjson span_count "${span_count}" \
    --argjson decision_count "${decision_count}" \
    --argjson review_queue_count "${rq_count}" \
    --arg newest_review_event "${newest_review_event}" \
    --argjson spans "${spans_json}" \
    --argjson attributions "${attrib_json}" \
    --argjson review_queue "${rq_json}" \
    '{
      interaction_id: $interaction_id,
      ready: ($ready == "yes"),
      span_count: $span_count,
      decision_count: $decision_count,
      review_queue_count: $review_queue_count,
      newest_review_event: $newest_review_event,
      spans: $spans,
      attributions: $attributions,
      review_queue: $review_queue
    }' > "${out_file}"

  echo "${ready}"
}

pending_ids=("${interaction_ids[@]}")
poll_start_epoch="$(date -u +%s)"

while :; do
  next_pending=()
  for iid in "${pending_ids[@]}"; do
    status_file="${POLL_OUT_DIR}/${iid}.json"
    ready="$(check_interaction_ready "${iid}" "${status_file}")"
    if [[ "${ready}" != "yes" ]]; then
      next_pending+=("${iid}")
    fi
  done

  pending_ids=("${next_pending[@]}")
  if [[ ${#pending_ids[@]} -eq 0 ]]; then
    break
  fi

  now_epoch="$(date -u +%s)"
  elapsed="$((now_epoch - poll_start_epoch))"
  if [[ ${elapsed} -ge ${POLL_TIMEOUT_SECONDS} ]]; then
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

ready_count=0
for iid in "${interaction_ids[@]}"; do
  status_file="${POLL_OUT_DIR}/${iid}.json"
  if [[ -f "${status_file}" ]] && jq -e '.ready == true' "${status_file}" >/dev/null 2>&1; then
    ready_count=$((ready_count + 1))
  fi
done

synthetic_ids_csv="$(IFS=,; echo "${interaction_ids[*]}")"
ios_stdout="${OUT_DIR}/ios_smoke_stdout.log"

set +e
bash "${IOS_SMOKE_SCRIPT}" --synthetic-ids "${synthetic_ids_csv}" > "${ios_stdout}" 2>&1
ios_rc=$?
set -e

ios_out_dir="$(grep -E '^out_dir=' "${ios_stdout}" | tail -n 1 | cut -d'=' -f2-)"
ios_summary_file=""
smoke_markers_file=""
device_udid=""
if [[ -n "${ios_out_dir}" && -f "${ios_out_dir}/summary.txt" ]]; then
  ios_summary_file="${ios_out_dir}/summary.txt"
  smoke_markers_file="$(grep -E '^smoke_markers=' "${ios_summary_file}" | cut -d'=' -f2-)"
  device_udid="$(grep -E '^device_udid=' "${ios_summary_file}" | cut -d'=' -f2-)"
fi

triage_action_count=0
triage_action_request_id_count=0
matched_synthetic_interactions=0
newest_inapp_event=""

if [[ -n "${smoke_markers_file}" && -f "${smoke_markers_file}" ]]; then
  triage_action_count="$(grep -c 'SMOKE_EVENT TRIAGE_ACTION' "${smoke_markers_file}" || true)"
  triage_action_request_id_count="$(
    grep 'SMOKE_EVENT TRIAGE_ACTION' "${smoke_markers_file}" \
      | grep -vc 'request_id=missing' \
      || true
  )"

  for iid in "${interaction_ids[@]}"; do
    if grep -q "interaction=${iid}" "${smoke_markers_file}"; then
      matched_synthetic_interactions=$((matched_synthetic_interactions + 1))
    fi
  done

  newest_inapp_event="$(
    grep -oE 'event_at=[^ ]+' "${smoke_markers_file}" \
      | sed 's/^event_at=//' \
      | sort \
      | tail -n 1 \
      || true
  )"
fi

freshness_pass=false
if [[ -n "${newest_inapp_event}" ]]; then
  if [[ "${newest_inapp_event}" > "${CUTOFF_DATE_UTC}" || "${newest_inapp_event}" == "${CUTOFF_DATE_UTC}" ]]; then
    freshness_pass=true
  fi
fi

non_synth_latest="$(
  curl -sf \
    "${SUPABASE_URL}/rest/v1/review_queue?select=interaction_id,event_at_utc,created_at&order=event_at_utc.desc&limit=50" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    2>/dev/null \
    | jq -r '[.[] | select((.interaction_id // "") | startswith("cll_SYNTH_") | not)][0].event_at_utc // empty' \
    || true
)"

gate_pass=true
if [[ ${synthetics_fail_count} -gt 0 ]]; then
  gate_pass=false
fi
if [[ ${ready_count} -lt ${#interaction_ids[@]} ]]; then
  gate_pass=false
fi
if [[ ${ios_rc} -ne 0 ]]; then
  gate_pass=false
fi
if [[ ${triage_action_count} -lt 1 ]]; then
  gate_pass=false
fi
if [[ ${triage_action_request_id_count} -lt 1 ]]; then
  gate_pass=false
fi
if [[ ${matched_synthetic_interactions} -lt 1 ]]; then
  gate_pass=false
fi
if [[ "${freshness_pass}" != "true" ]]; then
  gate_pass=false
fi

jq -n \
  --arg run_id "${RUN_ID}" \
  --arg cutoff_utc "${CUTOFF_DATE_UTC}" \
  --arg newest_inapp_event "${newest_inapp_event}" \
  --arg non_synth_latest "${non_synth_latest}" \
  --arg ios_out_dir "${ios_out_dir}" \
  --arg device_udid "${device_udid}" \
  --argjson synthetics_fail_count "${synthetics_fail_count}" \
  --argjson scenario_count "${#scenario_ids[@]}" \
  --argjson ready_count "${ready_count}" \
  --argjson interaction_count "${#interaction_ids[@]}" \
  --argjson ios_rc "${ios_rc}" \
  --argjson triage_action_count "${triage_action_count}" \
  --argjson triage_action_request_id_count "${triage_action_request_id_count}" \
  --argjson matched_synthetic_interactions "${matched_synthetic_interactions}" \
  --argjson gate_pass "$(if [[ "${gate_pass}" == "true" ]]; then echo true; else echo false; fi)" \
  --argjson scenario_ids "$(printf '%s\n' "${scenario_ids[@]}" | jq -R . | jq -s .)" \
  --argjson interaction_ids "$(printf '%s\n' "${interaction_ids[@]}" | jq -R . | jq -s .)" \
  '{
    run_id: $run_id,
    scenario_ids: $scenario_ids,
    interaction_ids: $interaction_ids,
    scenario_count: $scenario_count,
    synthetics_fail_count: $synthetics_fail_count,
    readiness: {
      ready_count: $ready_count,
      interaction_count: $interaction_count
    },
    ios_smoke: {
      exit_code: $ios_rc,
      device_udid: $device_udid,
      out_dir: $ios_out_dir,
      triage_action_count: $triage_action_count,
      triage_action_request_id_count: $triage_action_request_id_count,
      matched_synthetic_interactions: $matched_synthetic_interactions
    },
    freshness: {
      cutoff_utc: $cutoff_utc,
      newest_inapp_event: $newest_inapp_event,
      newest_non_synthetic_event: $non_synth_latest
    },
    gate_pass: $gate_pass
  }' > "${OUT_DIR}/summary.json"

echo "SYNTHETICS_PROOF: run_id=${RUN_ID} scenarios=${#scenario_ids[@]} ready=${ready_count}/${#interaction_ids[@]} failures=${synthetics_fail_count}"
echo "SYNTHETICS_SCENARIOS: $(IFS=,; echo "${scenario_ids[*]}")"
echo "SYNTHETICS_INTERACTIONS: ${synthetic_ids_csv}"
echo "IOS_SIM_PROOF: run_id=${RUN_ID} device=${device_udid:-unknown} triage_actions=${triage_action_count} request_ids=${triage_action_request_id_count} matched_synthetics=${matched_synthetic_interactions}"
echo "TRIAGE_FRESHNESS: cutoff=${CUTOFF_DATE_UTC} newest_inapp=${newest_inapp_event:-missing} newest_non_synthetic=${non_synth_latest:-missing}"
echo "ARTIFACT_DIR: artifacts/ios_synthetics_e2e/${RUN_ID}"

if [[ "${gate_pass}" != "true" ]]; then
  exit 1
fi

exit 0
