#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios/CamberRedline"
BUNDLE_ID="com.heartwoodcustombuilders.CamberRedline"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ROOT_DIR}/artifacts/ios_simulator_smoke/${STAMP}"
DERIVED_DIR="${OUT_DIR}/DerivedData"
SCREEN_DIR="${OUT_DIR}/screens"
mkdir -p "${SCREEN_DIR}"

# In sandboxed sessions, toolchains cannot always write under ~/Library.
# Use a local HOME for simctl + xcodebuild.
SIMCTL_HOME="${ROOT_DIR}/.simctl-home"
mkdir -p "${SIMCTL_HOME}/Library/Logs/CoreSimulator"

simctl() {
  HOME="${SIMCTL_HOME}" xcrun simctl "$@"
}

wait_for_simctl() {
  local max_tries=8
  local try
  for try in $(seq 1 "${max_tries}"); do
    if simctl list devices >/dev/null 2>&1; then
      return 0
    fi
    echo "[smoke] waiting for CoreSimulatorService (${try}/${max_tries})"
    open -a Simulator >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}

echo "[smoke] output: ${OUT_DIR}"

if ! wait_for_simctl; then
  echo "ERROR: CoreSimulatorService unavailable" >&2
  exit 1
fi

DEVICE_UDID="$(simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}')"
if [[ -z "${DEVICE_UDID}" ]]; then
  DEVICE_UDID="$(simctl list devices available | awk -F '[()]' '/iPhone 16/{print $2; exit}')"
  if [[ -z "${DEVICE_UDID}" ]]; then
    echo "ERROR: no simulator found" >&2
    exit 1
  fi
  simctl boot "${DEVICE_UDID}" || true
fi

open -a Simulator || true
simctl bootstatus "${DEVICE_UDID}" -b

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
) > "${OUT_DIR}/build.log" 2>&1

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
  --predicate "process == \"CamberRedline\"" > "${OUT_DIR}/app.log" 2>&1 &
LOG_PID=$!

echo "[smoke] recording video"
simctl io "${DEVICE_UDID}" recordVideo --codec h264 "${OUT_DIR}/session.mp4" >/dev/null 2>&1 &
VIDEO_PID=$!

cleanup() {
  kill "${VIDEO_PID}" >/dev/null 2>&1 || true
  kill "${LOG_PID}" >/dev/null 2>&1 || true
  wait "${VIDEO_PID}" >/dev/null 2>&1 || true
  wait "${LOG_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[smoke] launching app with automation flag"
simctl launch "${DEVICE_UDID}" "${BUNDLE_ID}" --smoke-drive > "${OUT_DIR}/launch.txt" 2>&1

for step in 01 02 03 04 05 06 07; do
  sleep 4
  simctl io "${DEVICE_UDID}" screenshot "${SCREEN_DIR}/shot_${step}.png" >/dev/null
done

sleep 2
cleanup
trap - EXIT

SMOKE_MARKERS="${OUT_DIR}/smoke_markers.log"
grep -E "SMOKE_EVENT" "${OUT_DIR}/app.log" > "${SMOKE_MARKERS}" || true

cat > "${OUT_DIR}/summary.txt" <<EOF
bundle_id=${BUNDLE_ID}
device_udid=${DEVICE_UDID}
out_dir=${OUT_DIR}
screens=${SCREEN_DIR}
video=${OUT_DIR}/session.mp4
build_log=${OUT_DIR}/build.log
app_log=${OUT_DIR}/app.log
smoke_markers=${SMOKE_MARKERS}
EOF

echo "[smoke] done"
cat "${OUT_DIR}/summary.txt"
