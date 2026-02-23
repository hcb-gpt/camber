#!/usr/bin/env bash
set -euo pipefail

# Write-enabled runner for the pending-window test-fixture triage backfill.
# This executes a scoped SQL patch that:
# - seeds review attributions for missing spans,
# - upserts attribution_audit_ledger test-fixture rows,
# - dismisses matching pending review_queue rows.
#
# Usage:
#   scripts/prod_test_fixture_pending_window_triage_backfill_v1.sh
#   PENDING_HOURS=2 MAX_AGE_DAYS=7 ACTOR=data-4 scripts/prod_test_fixture_pending_window_triage_backfill_v1.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null

PENDING_HOURS="${PENDING_HOURS:-2}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
ACTOR="${ACTOR:-data-4}"

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL is not set after loading env." >&2
  exit 1
fi

PSQL_BIN="${PSQL_PATH:-psql}"
if [[ "${PSQL_BIN}" == */* ]]; then
  if [[ ! -x "${PSQL_BIN}" ]]; then
    echo "ERROR: psql not executable at PSQL_PATH=${PSQL_BIN}" >&2
    exit 1
  fi
else
  if ! command -v "${PSQL_BIN}" >/dev/null 2>&1; then
    echo "ERROR: psql not found in PATH (or set PSQL_PATH)." >&2
    exit 1
  fi
fi

"${PSQL_BIN}" "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -P pager=off \
  -v pending_hours="${PENDING_HOURS}" \
  -v max_age_days="${MAX_AGE_DAYS}" \
  -v actor="${ACTOR}" \
  -f "${ROOT_DIR}/scripts/sql/prod_test_fixture_pending_window_triage_backfill_v1.sql"
