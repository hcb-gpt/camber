#!/bin/bash
# scripts/synthetics/run_synthetics.sh
# Triggers synthetic interaction generation for testing.
# Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

set -euo pipefail

# Directory context
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT_DIR

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCENARIOS_DIR="${ROOT_DIR}/scripts/synthetics/scenarios"
RESULTS_DIR="${ROOT_DIR}/.scratch/synthetics/results"
mkdir -p "$RESULTS_DIR"

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
if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  log "ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set."
  exit 1
fi

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------
log "Loading scenarios from $SCENARIOS_DIR..."

SCENARIOS=$(find "$SCENARIOS_DIR" -name "*.json" -maxdepth 1)
SCENARIO_COUNT=$(echo "$SCENARIOS" | wc -l | tr -d ' ')

if [[ "$SCENARIO_COUNT" -eq 0 ]]; then
  log "ERROR: No scenario files found in $SCENARIOS_DIR."
  exit 1
fi

log "Found $SCENARIO_COUNT scenario(s)."

for SCENARIO_FILE in $SCENARIOS; do
  SCENARIO_ID=$(basename "$SCENARIO_FILE" .json)
  log "Processing scenario: $SCENARIO_ID"

  SCENARIO=$(cat "$SCENARIO_FILE")
  CONTACT_NAME=$(echo "$SCENARIO" | jq -r '.contact.name')
  CONTACT_PHONE=$(echo "$SCENARIO" | jq -r '.contact.phone')
  TRANSCRIPT=$(echo "$SCENARIO" | jq -r '.transcript')
  EXPECTED_DECISION=$(echo "$SCENARIO" | jq -r '.expected.decision')
  RESULT_FILE="$RESULTS_DIR/${SCENARIO_ID}_result.json"
  SCENARIO_EVENT_AT=$(echo "$SCENARIO" | jq -r '.event_at_utc // empty')

  # Generate a synthetic interaction_id
  SYNTH_ID="cll_SYNTH_$(echo "$SCENARIO_ID" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | head -c 30)"

  # process-call v4.3.x gates PASS on event_at_utc/call_start_utc presence.
  # Provide a timestamp by default so segment-call can be chained in CI.
  if [[ -n "$SCENARIO_EVENT_AT" ]]; then
    EVENT_AT_UTC="$SCENARIO_EVENT_AT"
  else
    EVENT_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  echo "  Invoking process-call with interaction_id=$SYNTH_ID ..."

  # Call process-call with synthetic payload
  # Using curl to trigger the function directly.
  RESPONSE=$(curl -s -X POST "${SUPABASE_URL}/functions/v1/process-call" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg iid "$SYNTH_ID" \
      --arg transcript "$TRANSCRIPT" \
      --arg contact_name "$CONTACT_NAME" \
      --arg contact_phone "$CONTACT_PHONE" \
      --arg event_at_utc "$EVENT_AT_UTC" \
      '{
        interaction_id: $iid,
        transcript: $transcript,
        contact_name: $contact_name,
        otherPartyPhone: $contact_phone,
        event_at_utc: $event_at_utc,
        call_start_utc: $event_at_utc,
        source: "test",
        dry_run: false
      }')")

  log "  Response: $RESPONSE"
  echo "$RESPONSE" > "$RESULT_FILE"
done

log "Synthetic interaction generation complete."
