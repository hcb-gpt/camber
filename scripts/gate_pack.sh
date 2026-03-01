#!/usr/bin/env bash
set -euo pipefail

# scripts/gate_pack.sh
#
# Gate-pack correctness: executes scripts/gate_pack.sql in a transaction and ROLLS BACK.
# Stdout (exactly one line):
#   GATEPACK|PASS|assertions_ok=true
# or
#   GATEPACK|FAIL|reason=...|headSHA=...

print_help() {
  cat <<'EOF'
Usage: scripts/gate_pack.sh [--help|-h]

Execute scripts/gate_pack.sql in a transaction and roll it back.
Requires:
  DATABASE_URL
Optional env:
  PSQL_PATH
  REQUIRE_LOAD_ENV=true
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "ERROR: unknown argument: $1" >&2
  print_help >&2
  exit 2
fi

: "${DATABASE_URL:?DATABASE_URL required}"

need_bin(){ command -v "$1" >/dev/null 2>&1; }

# Use PSQL_PATH if set, otherwise look for psql in PATH
PSQL="${PSQL_PATH:-psql}"
if [[ ! -x "$PSQL" ]] && ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "GATEPACK|FAIL|reason=missing_bin:psql|headSHA=unknown"
  exit 10
fi

for b in uuidgen git; do
  need_bin "$b" || { echo "GATEPACK|FAIL|reason=missing_bin:$b|headSHA=unknown"; exit 10; }
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

if [[ "${REQUIRE_LOAD_ENV:-}" == "true" && -n "$REPO_ROOT" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/load-env.sh"
  "${REPO_ROOT}/scripts/test-credentials.sh" >/dev/null
fi

SQL_FILE="${REPO_ROOT}/scripts/gate_pack.sql"
if [[ -z "$REPO_ROOT" || ! -f "$SQL_FILE" ]]; then
  echo "GATEPACK|FAIL|reason=missing_sql_file|headSHA=${HEAD_SHA}"
  exit 10
fi

iid_ok="$(uuidgen)"; iid_gap="$(uuidgen)"; iid_ovl="$(uuidgen)"; iid_single="$(uuidgen)"
call_ok="$(uuidgen)"; call_gap="$(uuidgen)"; call_ovl="$(uuidgen)"; call_single="$(uuidgen)"

interaction_id_ok="gatepack_ok_${iid_ok}"
interaction_id_bad_gap="gatepack_gap_${iid_gap}"
interaction_id_bad_overlap="gatepack_ovl_${iid_ovl}"
interaction_id_bad_single="gatepack_single_${iid_single}"

set +e
out="$(
  "$PSQL" -v ON_ERROR_STOP=1 \
    -v iid_ok="$iid_ok" -v iid_gap="$iid_gap" -v iid_ovl="$iid_ovl" -v iid_single="$iid_single" \
    -v call_ok="$call_ok" -v call_gap="$call_gap" -v call_ovl="$call_ovl" -v call_single="$call_single" \
    -v interaction_id_ok="$interaction_id_ok" \
    -v interaction_id_bad_gap="$interaction_id_bad_gap" \
    -v interaction_id_bad_overlap="$interaction_id_bad_overlap" \
    -v interaction_id_bad_single="$interaction_id_bad_single" \
    -c "begin;" \
    -f "$SQL_FILE" \
    -c "rollback;" \
    "$DATABASE_URL" 2>/dev/null
)"
rc=$?
set -e

# Extract the GATEPACK receipt line (not the last line, since ROLLBACK follows)
# Note: psql output may have leading space, so we trim and match GATEPACK anywhere
line="$(printf "%s\n" "$out" | grep -E 'GATEPACK\|' | tail -n 1 | tr -d '\r' | sed 's/^ *//')"

if [[ $rc -eq 0 && "$line" =~ ^GATEPACK\|PASS\| ]]; then
  echo "$line"
  exit 0
fi

echo "GATEPACK|FAIL|reason=sql_assertion_or_db_error|headSHA=${HEAD_SHA}"
exit 1
