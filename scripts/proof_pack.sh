#!/usr/bin/env bash
# proof_pack.sh
# Standard proof-pack runner for one interaction_id.
# Source: GPT-DEV-2 (STRAT_GPT-DEV-2_20260131T2355Z)
#
# Contract:
# - Emits a strict, grep-friendly one-liner starting with:
#     PROOF_PACK_RESULT=PASS ...
#   or
#     PROOF_PACK_RESULT=FAIL_... ...
# - Also emits spans-by-generation summary + coverage summary.
# - Writes artifacts to: artifacts/proof_pack/<interaction_id>/
#
# Requirements:
# - psql in PATH
# - scripts/load-env.sh (exports DATABASE_URL or equivalent)
# - scripts/test-credentials.sh (must output a PASS receipt line)
#
# Usage:
#   ./scripts/proof_pack.sh <interaction_id>
#
# Env:
#   STRICT_CHUNKING=1 (default)   # 1 enforces expected_min_spans rule; 0 disables strict span-count gate
#   PROOF_SQL=scripts/proof_pack.sql (default)
#   OUT_DIR=artifacts/proof_pack (default)

print_help() {
  cat <<'EOF'
Usage: ./scripts/proof_pack.sh [interaction_id] [--help|-h]

Run proof_pack.sql for a single interaction and emit PROOF_PACK_RESULT.
Defaults:
  interaction_id=cll_06DSX0CVZHZK72VCVW54EH9G3C
Env:
  STRICT_CHUNKING=1
  PROOF_SQL=scripts/proof_pack.sql
  OUT_DIR=artifacts/proof_pack
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

# REQUIRED: centralized env loading
# shellcheck source=/dev/null
if [[ -f "$HOME/.camber/load-credentials.sh" ]]; then
  source "$HOME/.camber/load-credentials.sh" 2>/dev/null || true
fi
if [[ -f "$ROOT/scripts/load-env.sh" ]]; then
  source "$ROOT/scripts/load-env.sh"
fi

# Check if DATABASE_URL is set (needed for psql)
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "PROOF_PACK_RESULT=FAIL_NO_DATABASE_URL headSHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "ERROR: DATABASE_URL not set. This script requires direct psql access." >&2
  echo "For REST API-based proof, use: ./scripts/score_module.sh attribution <interaction_id>" >&2
  exit 1
fi

# Use PSQL_PATH if set, otherwise look for psql in PATH
PSQL="${PSQL_PATH:-psql}"
if [[ ! -x "$PSQL" ]] && ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "PROOF_PACK_RESULT=FAIL_NO_PSQL headSHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "ERROR: psql not found. Set PSQL_PATH or add psql to PATH." >&2
  exit 1
fi

# OPTIONAL: credential test with PASS receipt
if [[ -x "$ROOT/scripts/test-credentials.sh" ]]; then
  CRED_OUT="$("$ROOT/scripts/test-credentials.sh" 2>&1)" || true
  PASS_LINE="$(printf '%s\n' "$CRED_OUT" | grep -E 'PASS' | head -n1 || true)"
  if [[ -z "$PASS_LINE" ]]; then
    echo "WARNING: Credential test did not return PASS line" >&2
  fi
fi

INTERACTION_ID="${1:-cll_06DSX0CVZHZK72VCVW54EH9G3C}"
STRICT_CHUNKING="${STRICT_CHUNKING:-1}"
PROOF_SQL="${PROOF_SQL:-$ROOT/scripts/proof_pack.sql}"
OUT_DIR="${OUT_DIR:-$ROOT/artifacts/proof_pack}"

# Check if proof SQL exists
if [[ ! -f "$PROOF_SQL" ]]; then
  echo "PROOF_PACK_RESULT=FAIL_NO_PROOF_SQL interaction_id=$INTERACTION_ID headSHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "ERROR: Proof SQL not found at: $PROOF_SQL" >&2
  exit 1
fi

RUN_DIR="$OUT_DIR/$INTERACTION_ID"
mkdir -p "$RUN_DIR"

RAW_OUT="$RUN_DIR/psql_output.txt"
CRED_TXT="$RUN_DIR/credentials_pass.txt"
STRICT_LINE_TXT="$RUN_DIR/strict_line.txt"

printf '%s\n' "${PASS_LINE:-NO_CRED_CHECK}" > "$CRED_TXT"

# Run proof SQL (streams full report; strict line is inside)
"$PSQL" "$DATABASE_URL" \
  -v ON_ERROR_STOP=1 \
  -v interaction_id="$INTERACTION_ID" \
  -v strict_chunking="$STRICT_CHUNKING" \
  -f "$PROOF_SQL" 2>&1 | tee "$RAW_OUT"

# Extract strict line (must exist exactly once)
STRICT_LINE="$(grep -E '^PROOF_PACK_RESULT=' "$RAW_OUT" | tail -n1 || true)"
if [[ -z "$STRICT_LINE" ]]; then
  echo "PROOF_PACK_RESULT=FAIL_NO_STRICT_LINE interaction_id=$INTERACTION_ID headSHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  exit 1
fi

printf '%s\n' "$STRICT_LINE" | tee "$STRICT_LINE_TXT"

# Exit nonzero on FAIL_* (CI-friendly)
if printf '%s\n' "$STRICT_LINE" | grep -q '^PROOF_PACK_RESULT=PASS'; then
  exit 0
fi
exit 1
