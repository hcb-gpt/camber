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

run_prompt() {
  local prompt="$1"
  local slug="$2"
  local payload
  payload="$(jq -n --arg message "${prompt}" '{message: $message}')"

  local raw_file="${OUT_DIR}/${slug}.sse"
  curl -sS -N -X POST "${FUNCTION_URL}" \
    "${CURL_HEADERS[@]}" \
    -d "${payload}" \
    --max-time 120 > "${raw_file}"

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

if grep -qi "winship residence" <<<"${ANSWER_A}"; then PASS_A=1; fi
if grep -qi "winship residence" <<<"${ANSWER_B}"; then PASS_B=1; fi

echo "CHECK_WINSHIP_Q1=${PASS_A}"
echo "CHECK_WINSHIP_Q2=${PASS_B}"

if [[ "${PASS_A}" -eq 1 && "${PASS_B}" -eq 1 ]]; then
  echo "HARNESS_STATUS=PASS"
else
  echo "HARNESS_STATUS=FAIL"
  exit 1
fi
