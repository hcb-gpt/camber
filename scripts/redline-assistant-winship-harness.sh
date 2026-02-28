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
FUNCTION_URL="${REDLINE_ASSISTANT_URL:-${SUPABASE_BASE}/functions/v1/redline-assistant}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/artifacts/redline_assistant_harness/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${OUT_DIR}"

if [[ -z "${SUPABASE_ANON_KEY:-}" && -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  export SUPABASE_ANON_KEY="${SUPABASE_SERVICE_ROLE_KEY}"
fi

CURL_HEADERS=(-H "Content-Type: application/json")
if [[ -n "${SUPABASE_ANON_KEY:-}" ]]; then
  CURL_HEADERS+=(-H "apikey: ${SUPABASE_ANON_KEY}")
  CURL_HEADERS+=(-H "Authorization: Bearer ${SUPABASE_ANON_KEY}")
fi

header_value() {
  local header_file="$1"
  local header_name="$2"
  awk -v target="$(tr '[:upper:]' '[:lower:]' <<<"${header_name}")" '
    {
      line = $0
      gsub(/\r/, "", line)
      lower = tolower(line)
      if (index(lower, target ":") == 1) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "${header_file}"
}

run_prompt() {
  local prompt="$1"
  local slug="$2"
  local payload
  payload="$(jq -n --arg message "${prompt}" '{message: $message}')"

  local raw_file="${OUT_DIR}/${slug}.sse"
  local header_file="${OUT_DIR}/${slug}.headers"
  curl -sS -N -X POST "${FUNCTION_URL}" \
    "${CURL_HEADERS[@]}" \
    -d "${payload}" \
    --max-time 120 \
    -D "${header_file}" \
    > "${raw_file}"

  local text_file="${OUT_DIR}/${slug}.txt"
  awk '/^data: /{sub(/^data: /,""); print}' "${raw_file}" \
    | grep -v '^\[DONE\]$' \
    | jq -r '.choices[0].delta.content // empty' \
    > "${text_file}" || true

  tr -d '\r\n' < "${text_file}"
}

PROMPT_A="Winship hardscape"
PROMPT_B="What projects do you have"

echo "== redline-assistant harness =="
echo "FUNCTION_URL=${FUNCTION_URL}"
echo "OUT_DIR=${OUT_DIR}"

ANSWER_A="$(run_prompt "${PROMPT_A}" "q1_winship_hardscape")"
ANSWER_B="$(run_prompt "${PROMPT_B}" "q2_projects_roster")"

echo
echo "Q1: ${PROMPT_A}"
echo "A1: ${ANSWER_A}"
echo
echo "Q2: ${PROMPT_B}"
echo "A2: ${ANSWER_B}"
echo

PASS_A=0
PASS_B=0
PASS_A_FACT=0

if grep -qi "winship residence" <<<"${ANSWER_A}"; then PASS_A=1; fi
if grep -qi "winship residence" <<<"${ANSWER_B}"; then PASS_B=1; fi

if grep -Eiq 'cll_[A-Za-z0-9]+' <<<"${ANSWER_A}" || grep -Eiq '[0-9]+[^[:alpha:]]*(calls|claims|loops|reviews|interactions|pending)' <<<"${ANSWER_A}"; then
  PASS_A_FACT=1
fi

REQ_A="$(header_value "${OUT_DIR}/q1_winship_hardscape.headers" "x-request-id")"
REQ_B="$(header_value "${OUT_DIR}/q2_projects_roster.headers" "x-request-id")"
CTX_REQ_A="$(header_value "${OUT_DIR}/q1_winship_hardscape.headers" "x-assistant-context-request-id")"
CTX_REQ_B="$(header_value "${OUT_DIR}/q2_projects_roster.headers" "x-assistant-context-request-id")"
CONTRACT_A="$(header_value "${OUT_DIR}/q1_winship_hardscape.headers" "x-assistant-context-contract-version")"
CONTRACT_B="$(header_value "${OUT_DIR}/q2_projects_roster.headers" "x-assistant-context-contract-version")"
MODEL_A="$(header_value "${OUT_DIR}/q1_winship_hardscape.headers" "x-model-id")"
MODEL_B="$(header_value "${OUT_DIR}/q2_projects_roster.headers" "x-model-id")"

echo "CHECK_WINSHIP_Q1=${PASS_A}"
echo "CHECK_WINSHIP_Q2=${PASS_B}"
echo "CHECK_RECENT_FACT_Q1=${PASS_A_FACT}"
echo "REQUEST_ID_Q1=${REQ_A:-NONE}"
echo "REQUEST_ID_Q2=${REQ_B:-NONE}"
echo "ASSISTANT_CONTEXT_REQUEST_ID_Q1=${CTX_REQ_A:-NONE}"
echo "ASSISTANT_CONTEXT_REQUEST_ID_Q2=${CTX_REQ_B:-NONE}"
echo "CONTRACT_VERSION_Q1=${CONTRACT_A:-NONE}"
echo "CONTRACT_VERSION_Q2=${CONTRACT_B:-NONE}"
echo "MODEL_Q1=${MODEL_A:-NONE}"
echo "MODEL_Q2=${MODEL_B:-NONE}"

SUMMARY_FILE="${OUT_DIR}/summary.txt"
cat > "${SUMMARY_FILE}" <<EOF
CHECK_WINSHIP_Q1=${PASS_A}
CHECK_WINSHIP_Q2=${PASS_B}
CHECK_RECENT_FACT_Q1=${PASS_A_FACT}
REQUEST_ID_Q1=${REQ_A:-NONE}
REQUEST_ID_Q2=${REQ_B:-NONE}
ASSISTANT_CONTEXT_REQUEST_ID_Q1=${CTX_REQ_A:-NONE}
ASSISTANT_CONTEXT_REQUEST_ID_Q2=${CTX_REQ_B:-NONE}
CONTRACT_VERSION_Q1=${CONTRACT_A:-NONE}
CONTRACT_VERSION_Q2=${CONTRACT_B:-NONE}
MODEL_Q1=${MODEL_A:-NONE}
MODEL_Q2=${MODEL_B:-NONE}
EOF
echo "SUMMARY_FILE=${SUMMARY_FILE}"

if [[ "${PASS_A}" -eq 1 && "${PASS_B}" -eq 1 && "${PASS_A_FACT}" -eq 1 ]]; then
  echo "HARNESS_STATUS=PASS"
else
  echo "HARNESS_STATUS=FAIL"
  exit 1
fi
