#!/bin/bash
# scripts/synthetics/run_synthetics.sh
# Triggers synthetic interaction generation for testing.
# Requires SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and EDGE_SHARED_SECRET.

set -euo pipefail

# Directory context
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT_DIR

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCENARIOS_FILE="${ROOT_DIR}/scripts/synthetics/scenarios.json"
RESULTS_DIR="${ROOT_DIR}/.scratch/synthetics/results"
mkdir -p "$RESULTS_DIR"

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
TARGET_SCENARIO=""
RUN_UUID=$(date +%s)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      TARGET_SCENARIO="${2:-}"
      shift 2
      ;;
    --timestamp)
      RUN_UUID="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

# Source environment if local
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

# Validate required variables
if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" || -z "${EDGE_SHARED_SECRET:-}" ]]; then
  log "ERROR: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and EDGE_SHARED_SECRET must be set."
  exit 1
fi

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------
if [[ ! -f "${SCENARIOS_FILE}" ]]; then
  log "ERROR: Scenarios file not found: ${SCENARIOS_FILE}"
  exit 1
fi

if [[ -n "${TARGET_SCENARIO}" ]]; then
  SCENARIO_JSON=$(jq -r ".[] | select(.scenario_id == \"${TARGET_SCENARIO}\")" "${SCENARIOS_FILE}")
  if [[ -z "${SCENARIO_JSON}" ]]; then
    log "ERROR: Scenario not found in JSON: ${TARGET_SCENARIO}"
    exit 1
  fi
  SCENARIO_IDS=("${TARGET_SCENARIO}")
else
  log "Loading all scenarios from ${SCENARIOS_FILE}..."
  SCENARIO_IDS=($(jq -r '.[].scenario_id' "${SCENARIOS_FILE}"))
fi

SCENARIO_COUNT=${#SCENARIO_IDS[@]}
log "Processing $SCENARIO_COUNT scenario(s)."

CREATED_INTERACTION_IDS=()

for SCENARIO_ID in "${SCENARIO_IDS[@]}"; do
  log "Processing scenario: $SCENARIO_ID"

  SCENARIO=$(jq -r ".[] | select(.scenario_id == \"$SCENARIO_ID\")" "${SCENARIOS_FILE}")
  
  CONTACT_NAME=$(echo "$SCENARIO" | jq -r '.contact.name')
  CONTACT_PHONE=$(echo "$SCENARIO" | jq -r '.contact.phone')
  TRANSCRIPT=$(echo "$SCENARIO" | jq -r '.transcript')
  SCENARIO_EVENT_AT=$(echo "$SCENARIO" | jq -r '.event_at_utc // empty')

  # Generate a synthetic interaction_id
  # MUST match gate script logic if possible, but we add a suffix to avoid duplicates
  # Wait, if I add a suffix, the gate script won't find it.
  # I'll update the gate script to support the suffix or just use the suffix in the gate script too.
  
  NORMALIZED_SID=$(echo "${SCENARIO_ID}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | cut -c 1-20)
  # Interaction ID MUST start with cll_SYNTH_ for the gate script's grep/logic
  SYNTH_ID="cll_SYNTH_${NORMALIZED_SID}_${RUN_UUID}"
  CREATED_INTERACTION_IDS+=("$SYNTH_ID")

  # Provide a timestamp
  if [[ -n "$SCENARIO_EVENT_AT" ]]; then
    EVENT_AT_UTC="$SCENARIO_EVENT_AT"
  else
    EVENT_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  log "  Invoking process-call with interaction_id=$SYNTH_ID ..."

  # Call process-call with synthetic payload
  RESPONSE=$(curl -s -X POST "${SUPABASE_URL}/functions/v1/process-call" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg iid "$SYNTH_ID" \
      --arg transcript "$TRANSCRIPT" \
      --arg contact_name "$CONTACT_NAME" \
      --arg contact_phone "$CONTACT_PHONE" \
      --arg event_at_utc "$EVENT_AT_UTC" \
      --argjson contact "$(echo "$SCENARIO" | jq '.contact')" \
      --argjson candidates "$(echo "$SCENARIO" | jq '.candidates')" \
      --argjson journal_claims "$(echo "$SCENARIO" | jq '.journal_claims // []')" \
      --argjson continuity_context "$(echo "$SCENARIO" | jq '.continuity_context // null')" \
      '{
        interaction_id: $iid,
        transcript: $transcript,
        contact_name: $contact_name,
        otherPartyPhone: $contact_phone,
        event_at_utc: $event_at_utc,
        call_start_utc: $event_at_utc,
        source: "test",
        dry_run: false,
        synthetic_context: {
          contact: $contact,
          candidates: $candidates,
          journal_claims: $journal_claims,
          continuity_context: $continuity_context
        }
      }')")

  log "  Response: $RESPONSE"
  echo "$RESPONSE" > "${RESULTS_DIR}/${SCENARIO_ID}_result.json"
done

log "Synthetic interaction generation complete."
# Output the interaction IDs created so the gate script can find them
echo "INTERACTION_IDS=$(IFS=,; echo "${CREATED_INTERACTION_IDS[*]}")"
