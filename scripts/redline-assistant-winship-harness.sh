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

if ! command -v awk >/dev/null 2>&1; then
  echo "ERROR: awk is required" >&2
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

BANNED_RE='UTC|\binbound\b|\boutbound\b|\binteraction(s)?\b|these interactions show'
ISO_DATE_RE='\b[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?(Z)?\b'
NEXT_STEP_RE='(^|[[:space:]])(Next:|Want me to|I can)'
HUMAN_TIME_RE='(this morning|this afternoon|this evening|today|tonight|tomorrow|yesterday|last night|[0-9]+[[:space:]]+days?[[:space:]]+ago|over a week ago)'
MAX_WORDS=200

PROMPT_SLUGS=("q1_permar_status" "q2_hurley_schedule")
PROMPT_TEXTS=("tell me about permar" "whos at hurley tomorrow")

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
  local slug="$1"
  local prompt="$2"
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

  tr '\n' ' ' < "${text_file}" | tr -s ' ' | sed 's/^ //; s/ $//'
}

echo "== redline-assistant harness =="
echo "FUNCTION_URL=${FUNCTION_URL}"
echo "OUT_DIR=${OUT_DIR}"

SUMMARY_FILE="${OUT_DIR}/summary.txt"
: > "${SUMMARY_FILE}"

HARNESS_STATUS=PASS
for i in "${!PROMPT_SLUGS[@]}"; do
  slug="${PROMPT_SLUGS[$i]}"
  prompt="${PROMPT_TEXTS[$i]}"
  answer="$(run_prompt "${slug}" "${prompt}")"
  text_file="${OUT_DIR}/${slug}.txt"
  header_file="${OUT_DIR}/${slug}.headers"

  word_count="$(awk '{c += NF} END {print c+0}' "${text_file}")"
  check_banned=1
  check_next=1
  check_human_time=1
  check_word_cap=1

  if grep -Eiq "${BANNED_RE}" <<<"${answer}" || grep -Eiq "${ISO_DATE_RE}" <<<"${answer}"; then
    check_banned=0
  fi
  if ! grep -Eiq "${NEXT_STEP_RE}" <<<"${answer}"; then
    check_next=0
  fi
  if ! grep -Eiq "${HUMAN_TIME_RE}" <<<"${answer}"; then
    check_human_time=0
  fi
  if [[ "${word_count}" -gt "${MAX_WORDS}" ]]; then
    check_word_cap=0
  fi

  check_style=1
  if [[ "${check_banned}" -ne 1 || "${check_next}" -ne 1 || "${check_human_time}" -ne 1 || "${check_word_cap}" -ne 1 ]]; then
    check_style=0
    HARNESS_STATUS=FAIL
  fi

  req_id="$(header_value "${header_file}" "x-request-id")"
  ctx_req_id="$(header_value "${header_file}" "x-assistant-context-request-id")"
  contract_ver="$(header_value "${header_file}" "x-assistant-context-contract-version")"
  model_id="$(header_value "${header_file}" "x-model-id")"

  echo
  echo "PROMPT_${slug}=${prompt}"
  echo "ANSWER_${slug}=${answer}"
  echo "CHECK_${slug}_NO_DUMP_TOKENS=${check_banned}"
  echo "CHECK_${slug}_HAS_NEXT_STEP=${check_next}"
  echo "CHECK_${slug}_HAS_HUMAN_TIME=${check_human_time}"
  echo "CHECK_${slug}_WORD_CAP=${check_word_cap} (words=${word_count}, cap=${MAX_WORDS})"
  echo "CHECK_${slug}_STYLE=${check_style}"
  echo "REQUEST_ID_${slug}=${req_id:-NONE}"
  echo "ASSISTANT_CONTEXT_REQUEST_ID_${slug}=${ctx_req_id:-NONE}"
  echo "CONTRACT_VERSION_${slug}=${contract_ver:-NONE}"
  echo "MODEL_${slug}=${model_id:-NONE}"

  {
    echo "PROMPT_${slug}=${prompt}"
    echo "CHECK_${slug}_NO_DUMP_TOKENS=${check_banned}"
    echo "CHECK_${slug}_HAS_NEXT_STEP=${check_next}"
    echo "CHECK_${slug}_HAS_HUMAN_TIME=${check_human_time}"
    echo "CHECK_${slug}_WORD_CAP=${check_word_cap}"
    echo "CHECK_${slug}_STYLE=${check_style}"
    echo "REQUEST_ID_${slug}=${req_id:-NONE}"
    echo "ASSISTANT_CONTEXT_REQUEST_ID_${slug}=${ctx_req_id:-NONE}"
    echo "CONTRACT_VERSION_${slug}=${contract_ver:-NONE}"
    echo "MODEL_${slug}=${model_id:-NONE}"
  } >> "${SUMMARY_FILE}"
done

echo "SUMMARY_FILE=${SUMMARY_FILE}"

if [[ "${HARNESS_STATUS}" == "PASS" ]]; then
  echo "HARNESS_STATUS=PASS"
else
  echo "HARNESS_STATUS=FAIL"
  exit 1
fi
