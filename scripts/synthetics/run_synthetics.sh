#!/usr/bin/env bash
# run_synthetics.sh — Synthetic test pack runner with invariant assertions + snapshot diffing
#
# Usage:
#   ./scripts/synthetics/run_synthetics.sh                    # full run against live pipeline
#   ./scripts/synthetics/run_synthetics.sh --dry-run           # validate scenarios + script logic only
#   ./scripts/synthetics/run_synthetics.sh --scenario <id>     # run one scenario
#   ./scripts/synthetics/run_synthetics.sh --help              # show help
#
# Requires: SUPABASE_URL, EDGE_SHARED_SECRET, SUPABASE_SERVICE_ROLE_KEY
#   Source from: source ~/.camber/credentials.env
#
# Exit codes: 0 = all pass, 1 = failures found, 2 = config error

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_FILE="$SCRIPT_DIR/scenarios.json"
BASELINES_DIR="$SCRIPT_DIR/baselines"
RESULTS_DIR="$SCRIPT_DIR/results"

# ── Defaults ───────────────────────────────────────────────────
DRY_RUN=false
SINGLE_SCENARIO=""
VERBOSE=false
RUN_TAG="${SYNTH_RUN_TAG:-$(date -u +%Y%m%dT%H%M%S)_$RANDOM}"
RUN_TAG="$(echo "$RUN_TAG" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"

# ── Parse args ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --scenario)
      SINGLE_SCENARIO="$2"
      shift 2
      ;;
    --timestamp)
      RUN_TAG="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--scenario <id>] [--timestamp <tag>] [--verbose] [--help]"
      echo ""
      echo "Options:"
      echo "  --dry-run         Validate scenario format and script logic without calling pipeline"
      echo "  --scenario <id>   Run a single scenario by ID"
      echo "  --timestamp <tag> Set explicit run tag (suffix for interaction IDs)"
      echo "  --verbose, -v     Print detailed output"
      echo "  --help, -h        Show this help"
      echo ""
      echo "Scenarios file: $SCENARIOS_FILE"
      echo "Baselines dir:  $BASELINES_DIR"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 2
      ;;
  esac
done

# ── Validate prerequisites ─────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq"
  exit 2
fi

if [[ ! -f "$SCENARIOS_FILE" ]]; then
  echo "ERROR: Scenarios file not found: $SCENARIOS_FILE"
  exit 2
fi

# Validate scenarios JSON
if ! jq empty "$SCENARIOS_FILE" 2>/dev/null; then
  echo "ERROR: Invalid JSON in $SCENARIOS_FILE"
  exit 2
fi

SCENARIO_COUNT=$(jq length "$SCENARIOS_FILE")
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CAMBER Synthetic Test Pack                                 ║"
echo "║  Scenarios: $SCENARIO_COUNT                                            ║"
echo "║  Mode: $(if $DRY_RUN; then echo "DRY-RUN (validation only)    "; else echo "LIVE (pipeline invocation)   "; fi)             ║"
echo "║  Run tag: $RUN_TAG                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Credential check (skip for dry-run) ───────────────────────
if ! $DRY_RUN; then
  if [[ -z "${SUPABASE_URL:-}" ]] || [[ -z "${EDGE_SHARED_SECRET:-}" ]] || [[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    if [[ -f "$HOME/.camber/credentials.env" ]]; then
      # shellcheck disable=SC1091
      source "$HOME/.camber/credentials.env"
    fi
  fi

  for var in SUPABASE_URL EDGE_SHARED_SECRET SUPABASE_SERVICE_ROLE_KEY; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: $var not set. Run: source ~/.camber/credentials.env"
      exit 2
    fi
  done
  BASE_URL="${SUPABASE_URL}/functions/v1"
fi

# ── Results dir ────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"

# ── Counters ───────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
RUN_INTERACTION_IDS=()

# ── Helper: assert_invariant ──────────────────────────────────
# Usage: assert_invariant <test_name> <condition_result> <detail>
assert_invariant() {
  local name="$1"
  local result="$2"  # "pass" or "fail"
  local detail="${3:-}"

  if [[ "$result" == "pass" ]]; then
    echo "    ✅ PASS: $name"
    if $VERBOSE && [[ -n "$detail" ]]; then
      echo "             $detail"
    fi
    return 0
  else
    echo "    ❌ FAIL: $name"
    if [[ -n "$detail" ]]; then
      echo "             $detail"
    fi
    return 1
  fi
}

# ── Helper: snapshot_diff ─────────────────────────────────────
# Compare actual result against baseline, output diff
snapshot_diff() {
  local scenario_id="$1"
  local actual_file="$2"
  local baseline_file="$BASELINES_DIR/${scenario_id}.json"

  if [[ ! -f "$baseline_file" ]]; then
    echo "    ⚠️  No baseline found for $scenario_id — skipping snapshot diff"
    return 0
  fi

  # Extract comparable fields from actual result
  local actual_decision actual_confidence actual_project_id
  actual_decision=$(jq -r '.decision // "null"' "$actual_file" 2>/dev/null || echo "null")
  actual_confidence=$(jq -r '.confidence // "null"' "$actual_file" 2>/dev/null || echo "null")
  actual_project_id=$(jq -r '.project_id // "null"' "$actual_file" 2>/dev/null || echo "null")

  # Extract baseline expectations
  local expected_decision confidence_min confidence_max
  expected_decision=$(jq -r '.baseline_snapshot.decision // "null"' "$baseline_file")
  confidence_min=$(jq -r '.baseline_snapshot.confidence_range[0] // 0' "$baseline_file")
  confidence_max=$(jq -r '.baseline_snapshot.confidence_range[1] // 1' "$baseline_file")

  local diff_found=false

  # Decision check
  if [[ "$actual_decision" != "$expected_decision" ]]; then
    echo "    📊 SNAPSHOT DIFF: decision expected=$expected_decision actual=$actual_decision"
    diff_found=true
  fi

  # Confidence range check
  if [[ "$actual_confidence" != "null" ]]; then
    local in_range
    in_range=$(echo "$actual_confidence $confidence_min $confidence_max" | awk '{
      if ($1 >= $2 && $1 <= $3) print "yes"; else print "no"
    }')
    if [[ "$in_range" == "no" ]]; then
      echo "    📊 SNAPSHOT DIFF: confidence=$actual_confidence outside range [$confidence_min, $confidence_max]"
      diff_found=true
    fi
  fi

  # must_not_be check
  local must_not_count
  must_not_count=$(jq -r '.expected_must_not_be | length' "$baseline_file")
  for ((i=0; i<must_not_count; i++)); do
    local forbidden
    forbidden=$(jq -r ".expected_must_not_be[$i]" "$baseline_file")
    if [[ "$actual_decision" == "$forbidden" ]]; then
      echo "    📊 SNAPSHOT DIFF: decision=$actual_decision is in must_not_be list"
      diff_found=true
    fi
  done

  if ! $diff_found; then
    echo "    📊 Snapshot: matches baseline"
  fi

  return 0
}

# ── Main loop ──────────────────────────────────────────────────
for i in $(seq 0 $((SCENARIO_COUNT - 1))); do
  SCENARIO=$(jq ".[$i]" "$SCENARIOS_FILE")
  SCENARIO_ID=$(echo "$SCENARIO" | jq -r '.scenario_id')
  DESCRIPTION=$(echo "$SCENARIO" | jq -r '.description')

  # Filter to single scenario if specified
  if [[ -n "$SINGLE_SCENARIO" ]] && [[ "$SCENARIO_ID" != "$SINGLE_SCENARIO" ]]; then
    continue
  fi

  echo "──────────────────────────────────────────────────────────────"
  echo "  Scenario: $SCENARIO_ID"
  echo "  $DESCRIPTION"
  echo "──────────────────────────────────────────────────────────────"

  # ── DRY-RUN: validate scenario structure ───────────────────
  if $DRY_RUN; then
    scenario_pass=true

    # Validate required fields
    for field in scenario_id description transcript expected; do
      if [[ "$(echo "$SCENARIO" | jq -r ".$field // \"__MISSING__\"")" == "__MISSING__" ]]; then
        echo "    ❌ FAIL: Missing required field: $field"
        scenario_pass=false
      fi
    done

    # Validate expected sub-fields
    for field in decision must_not_be invariants; do
      if [[ "$(echo "$SCENARIO" | jq -r ".expected.$field // \"__MISSING__\"")" == "__MISSING__" ]]; then
        echo "    ❌ FAIL: Missing expected.$field"
        scenario_pass=false
      fi
    done

    # Validate transcript is non-empty
    transcript_len=$(echo "$SCENARIO" | jq -r '.transcript | length')
    if [[ "$transcript_len" -lt 10 ]]; then
      echo "    ❌ FAIL: Transcript too short ($transcript_len chars)"
      scenario_pass=false
    fi

    # Validate candidates exist
    candidate_count=$(echo "$SCENARIO" | jq '.candidates | length')
    if [[ "$candidate_count" -lt 1 ]]; then
      echo "    ❌ FAIL: No candidates defined"
      scenario_pass=false
    fi

    # Validate baseline exists
    if [[ -f "$BASELINES_DIR/${SCENARIO_ID}.json" ]]; then
      if jq empty "$BASELINES_DIR/${SCENARIO_ID}.json" 2>/dev/null; then
        echo "    ✅ Baseline file valid"
      else
        echo "    ❌ FAIL: Invalid JSON in baseline file"
        scenario_pass=false
      fi
    else
      echo "    ⚠️  No baseline file (expected: $BASELINES_DIR/${SCENARIO_ID}.json)"
    fi

    # Validate invariants are named
    invariant_count=$(echo "$SCENARIO" | jq '.expected.invariants | length')
    echo "    📋 Invariants: $invariant_count"
    for ((j=0; j<invariant_count; j++)); do
      inv=$(echo "$SCENARIO" | jq -r ".expected.invariants[$j]")
      echo "       - $inv"
    done

    # Validate must_not_be
    must_not=$(echo "$SCENARIO" | jq -r '.expected.must_not_be | join(", ")')
    echo "    🚫 Must not be: $must_not"
    echo "    🎯 Expected decision: $(echo "$SCENARIO" | jq -r '.expected.decision')"
    echo "    👥 Candidates: $candidate_count"

    if $scenario_pass; then
      echo "    ✅ Scenario structure: VALID"
      ((PASS++))
    else
      echo "    ❌ Scenario structure: INVALID"
      ((FAIL++))
    fi
    echo ""
    continue
  fi

  # ── LIVE: invoke pipeline and check results ────────────────

  TRANSCRIPT=$(echo "$SCENARIO" | jq -r '.transcript')
  EXPECTED_DECISION=$(echo "$SCENARIO" | jq -r '.expected.decision')
  RESULT_FILE="$RESULTS_DIR/${SCENARIO_ID}_result.json"

  # Generate a synthetic interaction_id unique to this run.
  # Fixed IDs trigger process-call duplicate short-circuit ("decision=SKIP reason=duplicate"),
  # which prevents segment-call and yields null attribution proofs.
  NORMALIZED_SID=$(echo "${SCENARIO_ID}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | cut -c 1-20)
  SYNTH_ID="cll_SYNTH_${NORMALIZED_SID}_${RUN_TAG}"
  RUN_INTERACTION_IDS+=("$SYNTH_ID")

  echo "  Invoking process-call with interaction_id=$SYNTH_ID ..."

  # Call process-call with synthetic payload
  CONTACT_NAME=$(echo "$SCENARIO" | jq -r '.contact.contact_name // "Synthetic Caller"')
  CONTACT_PHONE=$(echo "$SCENARIO" | jq -r '.contact.phone // "+15555550000"')
  
  SCENARIO_EVENT_AT=$(echo "$SCENARIO" | jq -r '.event_at_utc // empty')
  if [[ -n "$SCENARIO_EVENT_AT" ]]; then
    EVENT_AT_UTC="$SCENARIO_EVENT_AT"
  else
    EVENT_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  HTTP_CODE=$(curl -s -o "$RESULT_FILE.raw" -w "%{http_code}" \
    -X POST "${BASE_URL}/process-call" \
    -H "Content-Type: application/json" \
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
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
        event_at_utc: $event_at_utc,
        eventAtUtc: $event_at_utc,
        direction: "inbound",
        ownerPhone: "+17065550000",
        ownerName: "Synthetic Owner",
        contact_name: $contact_name,
        otherPartyPhone: $contact_phone,
        source: "test",
        dry_run: false,
        synthetic_context: {
          contact: $contact,
          candidates: $candidates,
          journal_claims: $journal_claims,
          continuity_context: $continuity_context
        }
      }')" \
    2>/dev/null || echo "000")

  echo "  process-call HTTP: $HTTP_CODE"

  if [[ "$HTTP_CODE" -lt 200 ]] || [[ "$HTTP_CODE" -ge 300 ]]; then
    echo "    ❌ FAIL: process-call returned HTTP $HTTP_CODE"
    if $VERBOSE && [[ -f "$RESULT_FILE.raw" ]]; then
      echo "    Response: $(head -c 500 "$RESULT_FILE.raw")"
    fi
    ((FAIL++))
    echo ""
    continue
  fi

  # Wait for pipeline to process (segment-call -> context-assembly -> ai-router)
  echo "  Waiting 15s for pipeline chain to complete ..."
  sleep 15

  # Query span_attributions for results
  echo "  Querying span_attributions ..."

  QUERY_RESULT=$(curl -s -X POST \
    "${SUPABASE_URL}/rest/v1/rpc/query" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg iid "$SYNTH_ID" '{
      query: ("SELECT cs.span_index, cs.id AS span_id, sa.decision, sa.project_id, sa.applied_project_id, sa.confidence, sa.attribution_lock, sa.model_id, sa.prompt_version, sa.attributed_at, sa.candidates_snapshot, sa.matched_terms, sa.match_positions FROM conversation_spans cs LEFT JOIN span_attributions sa ON sa.span_id = cs.id WHERE cs.interaction_id = \u0027" + $iid + "\u0027 ORDER BY cs.span_index")
    }')" 2>/dev/null || echo "[]")

  # If RPC approach fails, try direct REST query
  if [[ "$QUERY_RESULT" == "[]" ]] || [[ -z "$QUERY_RESULT" ]] || echo "$QUERY_RESULT" | jq -e '.error' &>/dev/null; then
    # Direct query: get spans first
    SPANS_RESULT=$(curl -s \
      "${SUPABASE_URL}/rest/v1/conversation_spans?interaction_id=eq.${SYNTH_ID}&select=id,span_index,interaction_id&order=span_index" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      2>/dev/null || echo "[]")

    SPAN_COUNT=$(echo "$SPANS_RESULT" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$SPAN_COUNT" -gt 0 ]]; then
      # Get first span's attribution
      FIRST_SPAN_ID=$(echo "$SPANS_RESULT" | jq -r '.[0].id')
      ATTRIB_RESULT=$(curl -s \
        "${SUPABASE_URL}/rest/v1/span_attributions?span_id=eq.${FIRST_SPAN_ID}&select=decision,project_id,applied_project_id,confidence,candidates_snapshot,matched_terms,match_positions,model_id,prompt_version,attributed_at" \
        -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
        2>/dev/null || echo "[]")

      # Build combined result
      QUERY_RESULT=$(jq -n \
        --argjson spans "$SPANS_RESULT" \
        --argjson attribs "$ATTRIB_RESULT" \
        '{spans: $spans, attributions: $attribs}')
    else
      QUERY_RESULT='{"spans": [], "attributions": []}'
    fi
  fi

  # Save result
  echo "$QUERY_RESULT" | jq '.' > "$RESULT_FILE" 2>/dev/null || echo "$QUERY_RESULT" > "$RESULT_FILE"

  # ── Extract actual values ──────────────────────────────────
  ACTUAL_DECISION=$(echo "$QUERY_RESULT" | jq -r '
    if type == "array" then .[0].decision // "null"
    elif .attributions then .attributions[0].decision // "null"
    else "null" end
  ' 2>/dev/null || echo "null")

  ACTUAL_CONFIDENCE=$(echo "$QUERY_RESULT" | jq -r '
    if type == "array" then .[0].confidence // "null"
    elif .attributions then .attributions[0].confidence // "null"
    else "null" end
  ' 2>/dev/null || echo "null")

  ACTUAL_PROJECT_ID=$(echo "$QUERY_RESULT" | jq -r '
    if type == "array" then .[0].project_id // "null"
    elif .attributions then .attributions[0].project_id // "null"
    else "null" end
  ' 2>/dev/null || echo "null")

  echo "  Actual: decision=$ACTUAL_DECISION confidence=$ACTUAL_CONFIDENCE project=$ACTUAL_PROJECT_ID"

  # Write a normalized actual result for diffing
  jq -n \
    --arg decision "$ACTUAL_DECISION" \
    --arg confidence "$ACTUAL_CONFIDENCE" \
    --arg project_id "$ACTUAL_PROJECT_ID" \
    '{decision: $decision, confidence: $confidence, project_id: $project_id}' \
    > "$RESULT_FILE.normalized" 2>/dev/null

  # ── Run invariant assertions ───────────────────────────────
  scenario_pass=true

  # Check must_not_be
  must_not_count=$(echo "$SCENARIO" | jq '.expected.must_not_be | length')
  for ((j=0; j<must_not_count; j++)); do
    forbidden=$(echo "$SCENARIO" | jq -r ".expected.must_not_be[$j]")
    if [[ "$ACTUAL_DECISION" == "$forbidden" ]]; then
      assert_invariant "must_not_be:$forbidden" "fail" "actual=$ACTUAL_DECISION" || scenario_pass=false
    else
      assert_invariant "must_not_be:$forbidden" "pass" "actual=$ACTUAL_DECISION is not $forbidden"
    fi
  done

  # Check expected decision
  if [[ "$ACTUAL_DECISION" == "$EXPECTED_DECISION" ]]; then
    assert_invariant "expected_decision" "pass" "actual=$ACTUAL_DECISION matches expected=$EXPECTED_DECISION"
  else
    # Check alternatives
    alt_match=false
    alt_count=$(echo "$SCENARIO" | jq '.expected.decision_alternatives | length' 2>/dev/null || echo "0")
    for ((j=0; j<alt_count; j++)); do
      alt=$(echo "$SCENARIO" | jq -r ".expected.decision_alternatives[$j]")
      if [[ "$ACTUAL_DECISION" == "$alt" ]]; then
        alt_match=true
        break
      fi
    done
    if $alt_match; then
      assert_invariant "expected_decision" "pass" "actual=$ACTUAL_DECISION matches alternative"
    else
      assert_invariant "expected_decision" "fail" "actual=$ACTUAL_DECISION expected=$EXPECTED_DECISION" || scenario_pass=false
    fi
  fi

  # Check confidence bounds
  if [[ -n "$(echo "$SCENARIO" | jq -r '.expected.confidence_max // empty')" ]]; then
    CONF_MAX=$(echo "$SCENARIO" | jq -r '.expected.confidence_max')
    if [[ "$ACTUAL_CONFIDENCE" != "null" ]]; then
      in_bound=$(echo "$ACTUAL_CONFIDENCE $CONF_MAX" | awk '{if ($1 <= $2) print "yes"; else print "no"}')
      if [[ "$in_bound" == "yes" ]]; then
        assert_invariant "confidence_max" "pass" "actual=$ACTUAL_CONFIDENCE <= max=$CONF_MAX"
      else
        assert_invariant "confidence_max" "fail" "actual=$ACTUAL_CONFIDENCE > max=$CONF_MAX" || scenario_pass=false
      fi
    fi
  fi

  if [[ -n "$(echo "$SCENARIO" | jq -r '.expected.confidence_min // empty')" ]]; then
    CONF_MIN=$(echo "$SCENARIO" | jq -r '.expected.confidence_min')
    if [[ "$ACTUAL_CONFIDENCE" != "null" ]]; then
      in_bound=$(echo "$ACTUAL_CONFIDENCE $CONF_MIN" | awk '{if ($1 >= $2) print "yes"; else print "no"}')
      if [[ "$in_bound" == "yes" ]]; then
        assert_invariant "confidence_min" "pass" "actual=$ACTUAL_CONFIDENCE >= min=$CONF_MIN"
      else
        assert_invariant "confidence_min" "fail" "actual=$ACTUAL_CONFIDENCE < min=$CONF_MIN" || scenario_pass=false
      fi
    fi
  fi

  # Check assigned_project_id if specified
  if [[ -n "$(echo "$SCENARIO" | jq -r '.expected.assigned_project_id // empty')" ]]; then
    EXPECTED_PID=$(echo "$SCENARIO" | jq -r '.expected.assigned_project_id')
    if [[ "$ACTUAL_PROJECT_ID" == "$EXPECTED_PID" ]]; then
      assert_invariant "assigned_project_id" "pass" "actual=$ACTUAL_PROJECT_ID matches"
    else
      assert_invariant "assigned_project_id" "fail" "actual=$ACTUAL_PROJECT_ID expected=$EXPECTED_PID" || scenario_pass=false
    fi
  fi

  # ── Snapshot diff ──────────────────────────────────────────
  if [[ -f "$RESULT_FILE.normalized" ]]; then
    snapshot_diff "$SCENARIO_ID" "$RESULT_FILE.normalized"
  fi

  # ── Scenario verdict ───────────────────────────────────────
  if $scenario_pass; then
    echo "  ✅ SCENARIO PASS: $SCENARIO_ID"
    ((PASS++))
  else
    echo "  ❌ SCENARIO FAIL: $SCENARIO_ID"
    ((FAIL++))
  fi
  echo ""
done

# ── Summary ────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo "══════════════════════════════════════════════════════════════"

# Output the interaction IDs created so the gate script can find them.
# Guard empty array expansion to avoid unbound-variable errors under set -u.
if [[ ${#RUN_INTERACTION_IDS[@]} -gt 0 ]]; then
  INTERACTION_IDS_CSV="$(IFS=,; echo "${RUN_INTERACTION_IDS[*]}")"
else
  INTERACTION_IDS_CSV=""
fi
echo "INTERACTION_IDS=${INTERACTION_IDS_CSV}"

if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  exit 0
fi
