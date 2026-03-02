#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios/CamberRedline"
BUNDLE_ID="com.heartwoodcustombuilders.CamberRedline"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PROOF_DATE="$(date +%Y-%m-%d)"
PROOF_DIR="${ROOT_DIR}/docs/proofs/ios/${PROOF_DATE}"
WORK_DIR="${ROOT_DIR}/.scratch/ios_simulator_smoke/${STAMP}_realtime_cleanup_proof"
DERIVED_DIR="${WORK_DIR}/DerivedData"

mkdir -p "${PROOF_DIR}"
mkdir -p "${WORK_DIR}"

# In sandboxed sessions, toolchains cannot always write under ~/Library.
# Use a local HOME for simctl + xcodebuild.
SIMCTL_HOME="${ROOT_DIR}/.simctl-home"
mkdir -p "${SIMCTL_HOME}/Library/Logs/CoreSimulator"

simctl() {
  HOME="${SIMCTL_HOME}" xcrun simctl "$@"
}

wait_for_simctl() {
  local max_tries=12
  local try
  for try in $(seq 1 "${max_tries}"); do
    if simctl list devices >/dev/null 2>&1; then
      return 0
    fi
    echo "[smoke] waiting for CoreSimulatorService (${try}/${max_tries})"
    open -a Simulator >/dev/null 2>&1 || true
    sleep 3
  done
  simctl list devices >/dev/null 2>&1
}

pick_simulator_udid() {
  local udid=""

  # Prefer an already-booted iPhone (reduces flakiness and avoids iPad/Mac-catalyst destinations).
  udid="$(simctl list devices | awk -F '[()]' '/Booted/ && /iPhone/{print $2; exit}')"
  if [[ -n "${udid}" ]]; then
    echo "${udid}"
    return 0
  fi

  # Prefer newest iPhones (common CI/dev defaults).
  for pref in "iPhone 17" "iPhone 16" "iPhone 15"; do
    udid="$(simctl list devices available | awk -F '[()]' -v pref="${pref}" '$0 ~ pref {print $2; exit}')"
    if [[ -n "${udid}" ]]; then
      echo "${udid}"
      return 0
    fi
  done

  # Fallback: first available iPhone.
  udid="$(simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
  if [[ -n "${udid}" ]]; then
    echo "${udid}"
    return 0
  fi

  return 1
}

is_booted() {
  local udid="${1}"
  simctl list devices | awk -v udid="${udid}" '$0 ~ udid && /Booted/ {found=1} END {exit !found}'
}

echo "[smoke] proof_dir: ${PROOF_DIR}"
echo "[smoke] work_dir: ${WORK_DIR}"

if ! wait_for_simctl; then
  echo "ERROR: CoreSimulatorService unavailable" >&2
  exit 1
fi

DEVICE_UDID="$(pick_simulator_udid || true)"
if [[ -z "${DEVICE_UDID}" ]]; then
  echo "ERROR: no iPhone simulator found" >&2
  exit 1
fi

if ! is_booted "${DEVICE_UDID}"; then
  simctl boot "${DEVICE_UDID}" || true
fi

open -a Simulator || true
simctl bootstatus "${DEVICE_UDID}" -b || {
  sleep 3
  simctl bootstatus "${DEVICE_UDID}" -b
}

echo "[smoke] building for simulator ${DEVICE_UDID}"
(
  cd "${IOS_DIR}"
  HOME="${SIMCTL_HOME}" xcodebuild \
    -project CamberRedline.xcodeproj \
    -scheme CamberRedline \
    -destination "id=${DEVICE_UDID}" \
    -derivedDataPath "${DERIVED_DIR}" \
    CODE_SIGNING_ALLOWED=NO \
    build
) > "${WORK_DIR}/build.raw.log" 2>&1

# Proof rule: avoid committing literal /Users/... paths
sed -E 's#/Users/[^/]+#<HOME>#g' "${WORK_DIR}/build.raw.log" > "${WORK_DIR}/build.log"
rm -f "${WORK_DIR}/build.raw.log"

APP_PATH="${DERIVED_DIR}/Build/Products/Debug-iphonesimulator/CamberRedline.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: built app missing at ${APP_PATH}" >&2
  exit 1
fi

echo "[smoke] installing app"
simctl install "${DEVICE_UDID}" "${APP_PATH}"
simctl terminate "${DEVICE_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

echo "[smoke] capturing device logs"
simctl spawn "${DEVICE_UDID}" log stream --style compact --level debug \
  --predicate "process == \"CamberRedline\"" > "${WORK_DIR}/app.log" 2>&1 &
LOG_PID=$!

cleanup() {
  kill "${LOG_PID}" >/dev/null 2>&1 || true
  wait "${LOG_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[smoke] launching app with realtime cleanup proof flags"
export SIMCTL_CHILD_SMOKE_FORCE_CLAIM_GRADES_CANCEL=1
export SIMCTL_CHILD_SMOKE_FORCE_THREAD_INTERACTIONS_SUBSCRIBE_FAIL=1
export SIMCTL_CHILD_SMOKE_FORCE_CONTACTLIST_SUBSCRIBE_FAIL=1

simctl launch "${DEVICE_UDID}" "${BUNDLE_ID}" --smoke-realtime-cleanup-proof > "${WORK_DIR}/launch.txt" 2>&1

sleep 4
simctl terminate "${DEVICE_UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

cleanup
trap - EXIT

SMOKE_MARKERS="${WORK_DIR}/smoke_markers.log"
grep -E "SMOKE_EVENT" "${WORK_DIR}/app.log" > "${SMOKE_MARKERS}" || true

PROOF_MARKERS="${PROOF_DIR}/realtime_cleanup_smoke_markers_${STAMP}.log"
grep -E "REALTIME_CLEANUP_PROOF" "${SMOKE_MARKERS}" > "${PROOF_MARKERS}" || true

require_marker() {
  local needle="${1}"
  if ! grep -E "${needle}" "${PROOF_MARKERS}" >/dev/null 2>&1; then
    echo "ERROR: missing marker: ${needle}" >&2
    echo "see: ${PROOF_MARKERS}" >&2
    sed -n '1,200p' "${PROOF_MARKERS}" >&2 || true
    exit 1
  fi
}

require_marker "REALTIME_CLEANUP_PROOF_START"
require_marker "claim_grades_cleanup_ok=true"
require_marker "thread_interactions_removed_review_queue=1"
require_marker "thread_interactions_channels_cleared=true"
require_marker "contactlist_removed_review_queue=1"
require_marker "REALTIME_CLEANUP_PROOF_END"

echo "[smoke] PASS"
echo "[smoke] markers: ${PROOF_MARKERS}"
