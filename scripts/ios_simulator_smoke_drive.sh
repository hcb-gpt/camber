#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios/CamberRedline"
BUNDLE_ID="com.heartwoodcustombuilders.CamberRedline"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ROOT_DIR}/artifacts/ios_simulator_smoke/${STAMP}"
DERIVED_DIR="${OUT_DIR}/DerivedData"
SCREEN_DIR="${OUT_DIR}/screens"
SYNTHETIC_IDS="${SYNTHETIC_IDS:-}"
DRY_RUN=0
TRUTH_SURFACE=0
TRUTH_SURFACE_LOCAL=0
WRITE_LOCK_RECOVERY=0
RECOVERY_PROBE_QUEUE_ID="${SMOKE_RECOVERY_PROBE_QUEUE_ID:-}"
SCREEN_STEPS=7
SCREEN_INTERVAL_SECONDS=4
SMOKE_MARKER_STRICT_SINGLE_RUN="${SMOKE_MARKER_STRICT_SINGLE_RUN:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/ios_simulator_smoke_drive.sh [options]

Options:
  --synthetic-ids <csv>   Comma-separated interaction IDs to target in triage smoke.
  --truth-surface         Run picker-first truth surface smoke (adds --smoke-truth-surface).
  --truth-surface-local   Run truth surface smoke with a local synthetic queue (no network).
  --write-lock-recovery   Run write-lock recovery smoke (adds --smoke-write-lock-recovery).
  --recovery-probe-queue-id <id>  Override recovery probe review_queue_id (debug regression aid).
  --dry-run               Print chosen simulator and exit (no build).
  --help, -h              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --synthetic-ids)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: --synthetic-ids requires a comma-separated value" >&2
        usage >&2
        exit 2
      fi
      SYNTHETIC_IDS="${2}"
      shift 2
      ;;
    --truth-surface)
      TRUTH_SURFACE=1
      shift 1
      ;;
    --truth-surface-local)
      TRUTH_SURFACE=1
      TRUTH_SURFACE_LOCAL=1
      shift 1
      ;;
    --write-lock-recovery)
      WRITE_LOCK_RECOVERY=1
      shift 1
      ;;
    --recovery-probe-queue-id)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: --recovery-probe-queue-id requires a value" >&2
        usage >&2
        exit 2
      fi
      RECOVERY_PROBE_QUEUE_ID="${2}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

if [[ "${TRUTH_SURFACE}" -eq 1 ]]; then
  # Truth-surface proof wants tighter sampling around the triage sheet.
  SCREEN_STEPS=12
  SCREEN_INTERVAL_SECONDS=2
fi

if ! [[ "${SMOKE_MARKER_STRICT_SINGLE_RUN}" =~ ^[01]$ ]]; then
  echo "ERROR: SMOKE_MARKER_STRICT_SINGLE_RUN must be 0 or 1" >&2
  exit 2
fi

if [[ "${WRITE_LOCK_RECOVERY}" -eq 1 ]]; then
  # Recovery proof needs extra captures while the sheet transitions through checking -> unlocked.
  SCREEN_STEPS=14
  SCREEN_INTERVAL_SECONDS=2
fi

source "${ROOT_DIR}/scripts/ios_simulator_smoke_lib.sh"

if [[ "${DRY_RUN}" -eq 0 ]]; then
  echo "[smoke] output: ${OUT_DIR}"
fi

if ! wait_for_simctl; then
  echo "ERROR: CoreSimulatorService unavailable" >&2
  exit 1
fi

DEVICE_UDID="$(pick_simulator_udid || true)"
if [[ -z "${DEVICE_UDID}" ]]; then
  echo "ERROR: no iPhone simulator found" >&2
  exit 1
fi

DEVICE_NAME="$(device_name_for_udid "${DEVICE_UDID}" || true)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  cat <<EOF
device_udid=${DEVICE_UDID}
device_name=${DEVICE_NAME}
EOF
  exit 0
fi

mkdir -p "${SCREEN_DIR}"

if ! is_booted "${DEVICE_UDID}"; then
  simctl boot "${DEVICE_UDID}" || true
fi

open -a Simulator || true
# bootstatus can fail transiently under set -e; retry once after short wait
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
LAUNCH_ARGS=(--smoke-drive)
if [[ "${TRUTH_SURFACE}" -eq 1 ]]; then
  LAUNCH_ARGS+=(--smoke-truth-surface)
fi
if [[ "${TRUTH_SURFACE_LOCAL}" -eq 1 ]]; then
  LAUNCH_ARGS+=(--smoke-truth-surface-local)
fi
if [[ "${WRITE_LOCK_RECOVERY}" -eq 1 ]]; then
  LAUNCH_ARGS+=(--smoke-write-lock-recovery)
fi
if [[ -n "${SYNTHETIC_IDS}" ]]; then
  LAUNCH_ARGS+=(--smoke-synthetic-ids "${SYNTHETIC_IDS}")
fi

if [[ "${WRITE_LOCK_RECOVERY}" -eq 1 ]]; then
  export SIMCTL_CHILD_SMOKE_FORCE_WRITE_LOCK=1
  if [[ -n "${EDGE_SHARED_SECRET:-}" ]]; then
    export SIMCTL_CHILD_EDGE_SHARED_SECRET="${EDGE_SHARED_SECRET}"
  fi
  if [[ -n "${RECOVERY_PROBE_QUEUE_ID}" ]]; then
    export SIMCTL_CHILD_SMOKE_RECOVERY_PROBE_QUEUE_ID="${RECOVERY_PROBE_QUEUE_ID}"
  fi
fi
simctl launch "${DEVICE_UDID}" "${BUNDLE_ID}" "${LAUNCH_ARGS[@]}" > "${OUT_DIR}/launch.txt" 2>&1
unset SIMCTL_CHILD_SMOKE_FORCE_WRITE_LOCK || true
unset SIMCTL_CHILD_EDGE_SHARED_SECRET || true
unset SIMCTL_CHILD_SMOKE_RECOVERY_PROBE_QUEUE_ID || true

SMOKE_MARKER_PATTERN="SMOKE_EVENT START"
SMOKE_MARKER_TIMEOUT_SECONDS=20
SMOKE_MARKER_SEEN=0
SMOKE_MARKER_WAIT_SECONDS=0
if SMOKE_MARKER_WAIT_SECONDS="$(wait_for_log_pattern "${SMOKE_MARKER_PATTERN}" "${SMOKE_MARKER_TIMEOUT_SECONDS}" "${OUT_DIR}/app.log")"; then
  SMOKE_MARKER_SEEN=1
fi

for step in $(seq 1 "${SCREEN_STEPS}"); do
  sleep "${SCREEN_INTERVAL_SECONDS}"
  step_label=$(printf "%02d" "${step}")
  simctl io "${DEVICE_UDID}" screenshot "${SCREEN_DIR}/shot_${step_label}.png" >/dev/null
done

sleep 2
cleanup
trap - EXIT

SMOKE_LAUNCH_PID="$(sed -n 's/.*: \([0-9][0-9]*\)$/\1/p' "${OUT_DIR}/launch.txt" | tail -n 1 || true)"
SMOKE_LAUNCH_PID="${SMOKE_LAUNCH_PID:-unknown}"
SMOKE_MARKERS="${OUT_DIR}/smoke_markers.log"
SMOKE_MARKER_SCOPE_MODE="full_log"

# Prefer run-scoped extraction by launched PID. If no lines are captured (or PID is
# unknown), fall back to a single START..END window from the full log.
if [[ "${SMOKE_LAUNCH_PID}" != "unknown" ]]; then
  awk -v pid="${SMOKE_LAUNCH_PID}" \
    'index($0, "SMOKE_EVENT") && index($0, "[" pid ":") { print }' \
    "${OUT_DIR}/app.log" > "${SMOKE_MARKERS}" || true
  if [[ -s "${SMOKE_MARKERS}" ]]; then
    SMOKE_MARKER_SCOPE_MODE="launch_pid"
  fi
fi

if [[ ! -s "${SMOKE_MARKERS}" ]]; then
  awk '
    index($0, "SMOKE_EVENT") {
      if (!started && index($0, "SMOKE_EVENT START")) {
        started = 1
      }
      if (started) {
        print
      }
      if (started && index($0, "SMOKE_EVENT END")) {
        exit
      }
    }
  ' "${OUT_DIR}/app.log" > "${SMOKE_MARKERS}" || true
  if [[ -s "${SMOKE_MARKERS}" ]]; then
    SMOKE_MARKER_SCOPE_MODE="start_end_window"
  fi
fi

# Last resort for diagnostics: keep prior behavior if neither scoped extraction path produced output.
if [[ ! -s "${SMOKE_MARKERS}" ]]; then
  grep -E "SMOKE_EVENT" "${OUT_DIR}/app.log" > "${SMOKE_MARKERS}" || true
fi

SMOKE_MARKER_FIRST_LINE="$(grep -m 1 -E "${SMOKE_MARKER_PATTERN}" "${SMOKE_MARKERS}" 2>/dev/null || true)"
SMOKE_MARKER_START_COUNT="$(grep -E -c "SMOKE_EVENT START" "${SMOKE_MARKERS}" 2>/dev/null || true)"
SMOKE_MARKER_START_COUNT="${SMOKE_MARKER_START_COUNT:-0}"
SMOKE_MARKER_END_COUNT="$(grep -E -c "SMOKE_EVENT END" "${SMOKE_MARKERS}" 2>/dev/null || true)"
SMOKE_MARKER_END_COUNT="${SMOKE_MARKER_END_COUNT:-0}"

cat > "${OUT_DIR}/summary.txt" <<EOF
bundle_id=${BUNDLE_ID}
device_udid=${DEVICE_UDID}
device_name=${DEVICE_NAME}
out_dir=${OUT_DIR}
screens=${SCREEN_DIR}
video=${OUT_DIR}/session.mp4
build_log=${OUT_DIR}/build.log
app_log=${OUT_DIR}/app.log
smoke_markers=${SMOKE_MARKERS}
synthetic_ids=${SYNTHETIC_IDS}
write_lock_recovery=${WRITE_LOCK_RECOVERY}
recovery_probe_queue_id=${RECOVERY_PROBE_QUEUE_ID}
launch_args=${LAUNCH_ARGS[*]}
smoke_launch_pid=${SMOKE_LAUNCH_PID}
smoke_marker_scope_mode=${SMOKE_MARKER_SCOPE_MODE}
smoke_marker_pattern=${SMOKE_MARKER_PATTERN}
smoke_marker_seen=${SMOKE_MARKER_SEEN}
smoke_marker_wait_seconds=${SMOKE_MARKER_WAIT_SECONDS}
smoke_marker_first_line=${SMOKE_MARKER_FIRST_LINE}
smoke_marker_start_count=${SMOKE_MARKER_START_COUNT}
smoke_marker_end_count=${SMOKE_MARKER_END_COUNT}
smoke_marker_strict_single_run=${SMOKE_MARKER_STRICT_SINGLE_RUN}
EOF

if [[ "${SMOKE_MARKER_STRICT_SINGLE_RUN}" -eq 1 && "${SMOKE_MARKER_START_COUNT}" -ne 1 ]]; then
  echo "ERROR: strict smoke marker gate failed (launch_pid=${SMOKE_LAUNCH_PID}, start_count=${SMOKE_MARKER_START_COUNT}, end_count=${SMOKE_MARKER_END_COUNT})." >&2
  cat "${OUT_DIR}/summary.txt"
  exit 1
fi

echo "[smoke] done"
cat "${OUT_DIR}/summary.txt"
