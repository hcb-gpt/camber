#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${0:A}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios/CamberRedline"
SCHEME="CamberRedline"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR_REL="artifacts/xcodebuild_guard/${STAMP}"
OUT_DIR="${ROOT_DIR}/${OUT_DIR_REL}"
DERIVED_DIR="${OUT_DIR}/DerivedData"
LOG_RAW="${OUT_DIR}/build.raw.log"
LOG_SANITIZED="${OUT_DIR}/build.log"
SUMMARY_PATH="${OUT_DIR}/summary.txt"

mkdir -p "${OUT_DIR}"

# In sandboxed sessions, toolchains cannot always write under ~/Library.
# Use a local HOME for simctl + xcodebuild.
SIMCTL_HOME="${ROOT_DIR}/.simctl-home"
mkdir -p "${SIMCTL_HOME}/Library/Logs/CoreSimulator"

simctl() {
  HOME="${SIMCTL_HOME}" xcrun simctl "$@"
}

wait_for_simctl() {
  local max_tries=20
  local try

  open -a Simulator >/dev/null 2>&1 || true

  for try in $(seq 1 "${max_tries}"); do
    if simctl list devices >/dev/null 2>&1; then
      return 0
    fi
    echo "[guard] waiting for CoreSimulatorService (${try}/${max_tries})"
    sleep 2
  done
  return 1
}

echo "[guard] output: ${OUT_DIR_REL}"

if ! wait_for_simctl; then
  echo "ERROR: CoreSimulatorService unavailable" >&2
  exit 1
fi

PREFERRED_SIMULATOR_NAME="${PREFERRED_SIMULATOR_NAME:-iPhone 15}"

DEVICE_UDID="$(simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}')"
if [[ -z "${DEVICE_UDID}" ]]; then
  DEVICE_UDID="$(simctl list devices available | awk -F '[()]' -v name="${PREFERRED_SIMULATOR_NAME}" '$0 ~ name {print $2; exit}')"
fi
if [[ -z "${DEVICE_UDID}" ]]; then
  DEVICE_UDID="$(simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
fi

if [[ -z "${DEVICE_UDID}" ]]; then
  echo "ERROR: no iOS simulator device found" >&2
  exit 1
fi

echo "[guard] building scheme '${SCHEME}' for simulator ${DEVICE_UDID}"
mkdir -p "${DERIVED_DIR}"

set +e
(
  cd "${IOS_DIR}"
  HOME="${SIMCTL_HOME}" xcodebuild \
    -project CamberRedline.xcodeproj \
    -scheme "${SCHEME}" \
    -destination "id=${DEVICE_UDID}" \
    -derivedDataPath "${DERIVED_DIR}" \
    CODE_SIGNING_ALLOWED=NO \
    build
) > "${LOG_RAW}" 2>&1
BUILD_STATUS=$?
set -e

# Proof rule: commit artifacts without literal "/Users/..." paths.
sed -E 's#/Users/[^/]+#<HOME>#g' "${LOG_RAW}" > "${LOG_SANITIZED}"
rm -f "${LOG_RAW}"
rm -rf "${DERIVED_DIR}" >/dev/null 2>&1 || true

cat > "${SUMMARY_PATH}" <<EOF
out_dir=${OUT_DIR_REL}
scheme=${SCHEME}
preferred_simulator_name=${PREFERRED_SIMULATOR_NAME}
device_udid=${DEVICE_UDID}
build_status=${BUILD_STATUS}
build_log=${OUT_DIR_REL}/build.log
EOF

if [[ "${BUILD_STATUS}" -ne 0 ]]; then
  echo "[guard] BUILD FAILED (status=${BUILD_STATUS})"
  echo "[guard] see: ${OUT_DIR_REL}/build.log"
  exit "${BUILD_STATUS}"
fi

echo "[guard] BUILD SUCCEEDED"
echo "[guard] see: ${OUT_DIR_REL}/build.log"
