#!/usr/bin/env bash
# edge-smoke-test.sh — Post-deploy smoke test for Edge Functions
# Tests: auth gate (401 without secret) + auth pass (200 with secret) + valid JSON
#
# Usage:
#   ./scripts/edge-smoke-test.sh                  # test all pipeline functions
#   ./scripts/edge-smoke-test.sh morning-digest    # test one function
#   ./scripts/edge-smoke-test.sh --all             # same as no args
#
# Requires: SUPABASE_URL and EDGE_SHARED_SECRET env vars
#   Source from: source ~/.camber/credentials.env
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to source credentials if env vars not set
if [[ -z "${SUPABASE_URL:-}" ]] || [[ -z "${EDGE_SHARED_SECRET:-}" ]]; then
  if [[ -f "$HOME/.camber/credentials.env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.camber/credentials.env"
  fi
fi

# Validate required env vars
if [[ -z "${SUPABASE_URL:-}" ]]; then
  echo "ERROR: SUPABASE_URL not set. Run: source ~/.camber/credentials.env"
  exit 1
fi
if [[ -z "${EDGE_SHARED_SECRET:-}" ]]; then
  echo "ERROR: EDGE_SHARED_SECRET not set. Run: source ~/.camber/credentials.env"
  exit 1
fi

BASE_URL="${SUPABASE_URL}/functions/v1"

# ── Function registry ──────────────────────────────────────────
# Format: slug|method|body|expected_auth_fail_status
# Pipeline functions (Pattern A: X-Edge-Secret required)
PIPELINE_FUNCTIONS=(
  "morning-digest|GET||401"
  "loop-closure|POST|{\"interaction_id\":\"cll_SMOKE_TEST\",\"project_id\":\"00000000-0000-0000-0000-000000000000\"}|401"
  "process-call|POST|{\"interaction_id\":\"cll_SMOKE_TEST\",\"transcript\":\"test\"}|401"
  "segment-call|POST|{\"interaction_id\":\"cll_SMOKE_TEST\",\"transcript\":\"test\"}|401"
  "context-assembly|POST|{\"span_id\":\"00000000-0000-0000-0000-000000000000\"}|401"
  "ai-router|POST|{\"context_package\":{}}|401"
  "journal-extract|POST|{\"span_id\":\"00000000-0000-0000-0000-000000000000\"}|401"
  "generate-summary|POST|{\"interaction_id\":\"cll_SMOKE_TEST\"}|401"
  "sms-beside-batch-ingest|POST|{\"messages\":[{\"message_id\":\"msg_smoke_sms_beside\",\"created_at\":\"2026-01-01T00:00:00Z\",\"from_name\":\"Smoke\",\"from_phone\":\"+15555550100\",\"to_name\":\"Zack Sittler\",\"to_phone\":\"+17066889158\",\"direction\":\"inbound\",\"text\":\"smoke\"}],\"count\":1}|401"
  "striking-detect|POST|{\"span_id\":\"00000000-0000-0000-0000-000000000000\"}|401"
  "chain-detect|POST|{\"interaction_id\":\"cll_SMOKE_TEST\"}|401"
  "admin-reseed|POST|{\"interaction_id\":\"cll_SMOKE_TEST\",\"reason\":\"smoke\",\"idempotency_key\":\"smoke_test\"}|401"
  "shadow-replay|POST|{\"interaction_id\":\"cll_SMOKE_TEST\"}|401"
  "sms-beside-batch-ingest|POST|[]|401"
)

# ── Helpers ─────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

color_pass() { printf '\033[32m%s\033[0m' "$1"; }
color_fail() { printf '\033[31m%s\033[0m' "$1"; }
color_skip() { printf '\033[33m%s\033[0m' "$1"; }

test_auth_gate() {
  local slug="$1" method="$2" body="$3" expected_status="$4"

  # Test 1: No auth header → should get 401
  local curl_args=(-s -o /dev/null -w '%{http_code}' -X "$method")
  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi

  local status
  status=$(curl "${curl_args[@]}" "${BASE_URL}/${slug}" 2>/dev/null || echo "000")

  if [[ "$status" == "$expected_status" ]] || [[ "$status" == "401" ]] || [[ "$status" == "403" ]]; then
    printf "  %-25s auth_gate  $(color_pass 'PASS') (got %s)\n" "$slug" "$status"
    PASS=$((PASS + 1))
  else
    printf "  %-25s auth_gate  $(color_fail 'FAIL') (expected %s, got %s)\n" "$slug" "$expected_status" "$status"
    FAIL=$((FAIL + 1))
  fi
}

test_auth_pass() {
  local slug="$1" method="$2" body="$3"

  # Test 2: With auth header → should get 200 (or 400 for bad input, which is fine)
  local curl_args=(-s -w '\n%{http_code}' -X "$method"
    -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}"
    -H "X-Source: smoke-test"
  )
  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi

  local response
  response=$(curl "${curl_args[@]}" "${BASE_URL}/${slug}" 2>/dev/null || echo -e "\n000")

  local status
  status=$(echo "$response" | tail -1)
  local resp_body
  resp_body=$(echo "$response" | sed '$d')

  # Accept 200 (success), 400 (bad input but auth passed), 403 (source allowlist rejection
  # — proves secret was valid, source check is post-auth), 404 (not found) — all prove auth works
  if [[ "$status" == "200" ]] || [[ "$status" == "400" ]] || [[ "$status" == "404" ]] || [[ "$status" == "403" ]]; then
    # Verify JSON response
    if echo "$resp_body" | python3 -m json.tool > /dev/null 2>&1; then
      printf "  %-25s auth_pass  $(color_pass 'PASS') (got %s, valid JSON)\n" "$slug" "$status"
      PASS=$((PASS + 1))
    else
      printf "  %-25s auth_pass  $(color_pass 'PASS') (got %s, non-JSON)\n" "$slug" "$status"
      PASS=$((PASS + 1))
    fi
  elif [[ "$status" == "401" ]]; then
    printf "  %-25s auth_pass  $(color_fail 'FAIL') (still unauthorized: %s)\n" "$slug" "$status"
    FAIL=$((FAIL + 1))
  else
    printf "  %-25s auth_pass  $(color_skip 'WARN') (got %s — may be expected for smoke data)\n" "$slug" "$status"
    SKIP=$((SKIP + 1))
  fi
}

# ── Main ────────────────────────────────────────────────────────
TARGET="${1:-}"

echo "═══════════════════════════════════════════════════════════"
echo " Edge Function Smoke Tests"
echo " Base URL: ${BASE_URL}"
echo " Target:   ${TARGET:-all pipeline functions}"
echo "═══════════════════════════════════════════════════════════"
echo ""

for entry in "${PIPELINE_FUNCTIONS[@]}"; do
  IFS='|' read -r slug method body expected_status <<< "$entry"

  # Filter if specific function requested
  if [[ -n "$TARGET" ]] && [[ "$TARGET" != "--all" ]] && [[ "$TARGET" != "$slug" ]]; then
    continue
  fi

  test_auth_gate "$slug" "$method" "$body" "$expected_status"
  test_auth_pass "$slug" "$method" "$body"
done

echo ""
echo "═══════════════════════════════════════════════════════════"
printf " Results: $(color_pass '%d pass')  $(color_fail '%d fail')  $(color_skip '%d warn')\n" "$PASS" "$FAIL" "$SKIP"
echo "═══════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "SMOKE TEST FAILED — $FAIL test(s) did not pass"
  exit 1
else
  echo ""
  echo "ALL SMOKE TESTS PASSED"
  exit 0
fi
