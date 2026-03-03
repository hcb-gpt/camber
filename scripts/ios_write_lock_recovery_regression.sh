#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="${ROOT_DIR}/scripts/ios_simulator_smoke_drive.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${ROOT_DIR}/artifacts/ios_write_lock_recovery_regression/${STAMP}"
mkdir -p "${RUN_DIR}"

if [[ ! -x "${SMOKE_SCRIPT}" ]]; then
  echo "ERROR: missing smoke driver at ${SMOKE_SCRIPT}" >&2
  exit 1
fi

source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null 2>&1 || true
if [[ -z "${EDGE_SHARED_SECRET:-}" ]]; then
  echo "ERROR: EDGE_SHARED_SECRET must be set (try: source scripts/load-env.sh)" >&2
  exit 1
fi

run_case() {
  local case_name="$1"
  local probe_queue_id="$2"
  local expected_unlocked="$3"
  local expected_followup="$4"
  local case_log="${RUN_DIR}/${case_name}.log"

  echo "[recovery-regression] case=${case_name} expected_unlocked=${expected_unlocked}"
  if [[ -n "${probe_queue_id}" ]]; then
    EDGE_SHARED_SECRET="${EDGE_SHARED_SECRET}" \
      SMOKE_RECOVERY_PROBE_QUEUE_ID="${probe_queue_id}" \
      "${SMOKE_SCRIPT}" --write-lock-recovery | tee "${case_log}"
  else
    EDGE_SHARED_SECRET="${EDGE_SHARED_SECRET}" \
      "${SMOKE_SCRIPT}" --write-lock-recovery | tee "${case_log}"
  fi

  local out_dir
  out_dir="$(awk -F= '/^out_dir=/{print $2}' "${case_log}" | tail -n1)"
  if [[ -z "${out_dir}" ]]; then
    echo "ERROR: could not determine out_dir for case ${case_name}" >&2
    exit 1
  fi

  local markers="${out_dir}/smoke_markers.log"
  if [[ ! -f "${markers}" ]]; then
    echo "ERROR: missing smoke markers for case ${case_name}: ${markers}" >&2
    exit 1
  fi

  if ! grep -q "SMOKE_EVENT WRITE_LOCK_RECOVERY_RESULT unlocked=${expected_unlocked}" "${markers}"; then
    echo "ERROR: case ${case_name} expected unlocked=${expected_unlocked}" >&2
    exit 1
  fi

  if ! grep -q "${expected_followup}" "${markers}"; then
    echo "ERROR: case ${case_name} missing follow-up marker: ${expected_followup}" >&2
    exit 1
  fi

  {
    echo "case=${case_name}"
    echo "out_dir=${out_dir}"
    echo "markers=${markers}"
    echo "result=PASS"
  } > "${RUN_DIR}/${case_name}.summary.txt"
}

# Case 1: non-auth functional failure (400 missing_review_queue_id) must NOT unlock.
run_case \
  "non_auth_failure_preserves_lock" \
  "__invalid_recovery_probe__" \
  "0" \
  "SMOKE_EVENT WRITE_LOCK_RECOVERY_ABORT reason=still_locked"

# Case 2: explicit success contract (404 item_not_found with UUID probe) unlocks.
run_case \
  "explicit_success_unlocks" \
  "" \
  "1" \
  "SMOKE_EVENT WRITE_LOCK_RECOVERY_RETRY "

{
  echo "stamp=${STAMP}"
  echo "run_dir=${RUN_DIR}"
  echo "case_1_summary=${RUN_DIR}/non_auth_failure_preserves_lock.summary.txt"
  echo "case_2_summary=${RUN_DIR}/explicit_success_unlocks.summary.txt"
} > "${RUN_DIR}/summary.txt"

echo "[recovery-regression] PASS"
cat "${RUN_DIR}/summary.txt"
