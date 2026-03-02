#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFERRED_SIMULATOR_NAME_DEFAULT="iPhone 17 Pro"
BUNDLE_ID="com.heartwoodcustombuilders.CamberRedline"
SCHEME="CamberRedline"
PROJECT_NAME="CamberRedline.xcodeproj"

REMOTE_NAME="origin"
REF_DEFAULT="${REMOTE_NAME}/master"
DEVICE_NAME="${PREFERRED_SIMULATOR_NAME_DEFAULT}"
REF="${REF_DEFAULT}"
LOOP_INTERVAL_SECONDS=""
FORCE_BUILD="0"

STATE_DIR="${ROOT_DIR}/.temp/ios_sim_live"
RUN_DIR="${STATE_DIR}/latest"
DERIVED_DIR="${STATE_DIR}/DerivedData"
LAST_SHA_PATH="${STATE_DIR}/last_sha.txt"
LOCK_DIR="${STATE_DIR}/lock"
SIMCTL_HOME="${STATE_DIR}/simctl-home"

# A dedicated worktree avoids stomping on Chad's (often dirty) main checkout.
WORKTREE_DIR_DEFAULT="${HOME}/Library/Caches/hcb-gpt/camber-ios-sim-live"
WORKTREE_DIR="${WORKTREE_DIR_DEFAULT}"

usage() {
  cat <<'EOF'
Usage: scripts/ios_simulator_latest.sh [options]

Build + install + launch the latest CamberRedline iOS app on the iOS Simulator.
Designed to be safe even when your main camber checkout is dirty.

Options:
  --ref <git-ref>         Git ref to build (default: origin/master)
  --device <name>         Simulator device name (default: iPhone 17 Pro)
  --worktree <path>       Worktree path (default: ~/Library/Caches/hcb-gpt/camber-ios-sim-live)
  --force-build           Rebuild even if ref sha unchanged
  --loop <seconds>        Re-run every N seconds (semi-live). Prints progress each cycle.
  --help, -h              Show this help.

Examples:
  scripts/ios_simulator_latest.sh
  scripts/ios_simulator_latest.sh --loop 600
  scripts/ios_simulator_latest.sh --ref origin/master --device "iPhone 17 Pro"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --device)
      DEVICE_NAME="${2:-}"
      shift 2
      ;;
    --worktree)
      WORKTREE_DIR="${2:-}"
      shift 2
      ;;
    --force-build)
      FORCE_BUILD="1"
      shift
      ;;
    --loop)
      LOOP_INTERVAL_SECONDS="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "${RUN_DIR}" "${DERIVED_DIR}" "${SIMCTL_HOME}/Library/Logs/CoreSimulator"

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
    echo "[sim-live] waiting for CoreSimulatorService (${try}/${max_tries})"
    sleep 2
  done
  return 1
}

pick_device_udid() {
  local udid=""

  udid="$(simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}')"
  if [[ -z "${udid}" ]]; then
    udid="$(simctl list devices available | awk -F '[()]' -v name="${DEVICE_NAME}" '$0 ~ name {print $2; exit}')"
  fi
  if [[ -z "${udid}" ]]; then
    udid="$(simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
  fi
  if [[ -z "${udid}" ]]; then
    return 1
  fi
  echo "${udid}"
}

ensure_worktree() {
  local wt_parent
  wt_parent="$(dirname "${WORKTREE_DIR}")"
  mkdir -p "${wt_parent}"

  if [[ ! -d "${WORKTREE_DIR}" ]]; then
    echo "[sim-live] creating worktree: ${WORKTREE_DIR}"
    git -C "${ROOT_DIR}" fetch "${REMOTE_NAME}" --prune --quiet
    git -C "${ROOT_DIR}" worktree add --detach "${WORKTREE_DIR}" "${REF}" >/dev/null
    return 0
  fi

  if [[ ! -e "${WORKTREE_DIR}/.git" ]]; then
    echo "ERROR: worktree path exists but is not a git worktree: ${WORKTREE_DIR}" >&2
    echo "HINT: remove it, or pass --worktree to a fresh path." >&2
    exit 2
  fi
}

sync_worktree_to_ref() {
  git -C "${ROOT_DIR}" fetch "${REMOTE_NAME}" --prune --quiet
  git -C "${WORKTREE_DIR}" reset --hard "${REF}" >/dev/null
  git -C "${WORKTREE_DIR}" clean -fdx >/dev/null
  git -C "${WORKTREE_DIR}" rev-parse HEAD
}

with_lock() {
  if ! mkdir "${LOCK_DIR}" >/dev/null 2>&1; then
    echo "[sim-live] another run is in progress; exiting"
    exit 0
  fi
  trap 'rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true' EXIT
}

build_and_launch_once() {
  local stamp sha short_sha last_sha device_udid app_path build_log launch_log screenshot_path summary_path ios_dir
  local launch_status

  with_lock

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  ensure_worktree
  sha="$(sync_worktree_to_ref)"
  short_sha="${sha:0:7}"

  if ! wait_for_simctl; then
    echo "ERROR: CoreSimulatorService unavailable" >&2
    exit 1
  fi
  device_udid="$(pick_device_udid)" || {
    echo "ERROR: no iOS simulator device found" >&2
    exit 1
  }

  # Boot if needed.
  simctl boot "${device_udid}" >/dev/null 2>&1 || true
  simctl bootstatus "${device_udid}" -b >/dev/null 2>&1 || true
  open -a Simulator >/dev/null 2>&1 || true

  last_sha=""
  if [[ -f "${LAST_SHA_PATH}" ]]; then
    last_sha="$(cat "${LAST_SHA_PATH}" || true)"
  fi

  ios_dir="${WORKTREE_DIR}/ios/CamberRedline"
  build_log="${RUN_DIR}/build.log"
  launch_log="${RUN_DIR}/launch.txt"
  screenshot_path="${RUN_DIR}/screenshot.png"
  summary_path="${RUN_DIR}/summary.txt"

  app_path="${DERIVED_DIR}/Build/Products/Debug-iphonesimulator/CamberRedline.app"

  if [[ "${FORCE_BUILD}" == "1" || "${sha}" != "${last_sha}" || ! -d "${app_path}" ]]; then
    echo "[sim-live] build start ref=${REF} sha=${short_sha} device=${device_udid}"
    (
      cd "${ios_dir}"
      HOME="${SIMCTL_HOME}" xcodebuild \
        -project "${PROJECT_NAME}" \
        -scheme "${SCHEME}" \
        -destination "id=${device_udid}" \
        -derivedDataPath "${DERIVED_DIR}" \
        CODE_SIGNING_ALLOWED=NO \
        build
    ) > "${build_log}" 2>&1
    echo "${sha}" > "${LAST_SHA_PATH}"
  else
    echo "[sim-live] build skip (no new commits) sha=${short_sha}"
  fi

  if [[ ! -d "${app_path}" ]]; then
    echo "ERROR: built app missing at ${app_path}" >&2
    echo "HINT: see build log: ${build_log}" >&2
    exit 1
  fi

  echo "[sim-live] install + launch ${BUNDLE_ID}"
  simctl install "${device_udid}" "${app_path}" >/dev/null
  simctl terminate "${device_udid}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

  set +e
  simctl launch "${device_udid}" "${BUNDLE_ID}" > "${launch_log}" 2>&1
  launch_status=$?
  set -e

  if [[ "${launch_status}" -ne 0 ]]; then
    echo "[sim-live] WARNING: launch failed (status=${launch_status})"
    echo "[sim-live] see: ${launch_log}"
  fi

  # Give SwiftUI a moment to paint before screenshot.
  sleep 2
  simctl io "${device_udid}" screenshot "${screenshot_path}" >/dev/null 2>&1 || true

  cat > "${summary_path}" <<EOF
ts_utc=${stamp}
ref=${REF}
sha=${sha}
device_name=${DEVICE_NAME}
device_udid=${device_udid}
bundle_id=${BUNDLE_ID}
worktree=${WORKTREE_DIR}
build_log=.temp/ios_sim_live/latest/build.log
launch_log=.temp/ios_sim_live/latest/launch.txt
launch_status=${launch_status}
screenshot=.temp/ios_sim_live/latest/screenshot.png
EOF

  echo "[sim-live] done sha=${short_sha}"
  echo "[sim-live] screenshot: ${screenshot_path}"
  echo "[sim-live] summary: ${summary_path}"
}

if [[ -n "${LOOP_INTERVAL_SECONDS}" ]]; then
  if ! [[ "${LOOP_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || [[ "${LOOP_INTERVAL_SECONDS}" -lt 5 ]]; then
    echo "ERROR: --loop seconds must be an integer >= 5" >&2
    exit 2
  fi

  echo "[sim-live] loop enabled interval_seconds=${LOOP_INTERVAL_SECONDS}"
  while true; do
    echo "[sim-live] go"
    build_and_launch_once
    echo "[sim-live] wait ${LOOP_INTERVAL_SECONDS}"
    sleep "${LOOP_INTERVAL_SECONDS}"
  done
else
  build_and_launch_once
fi
