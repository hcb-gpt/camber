#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: ios_simulator_smoke_lib.sh is a library and must be sourced" >&2
  exit 2
fi

if [[ -z "${ROOT_DIR:-}" ]]; then
  echo "ERROR: ROOT_DIR must be set before sourcing ios_simulator_smoke_lib.sh" >&2
  return 2
fi

# In sandboxed sessions, toolchains cannot always write under ~/Library.
# Use a local HOME for simctl + xcodebuild.
SIMCTL_HOME="${SIMCTL_HOME:-${ROOT_DIR}/.simctl-home}"
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
  # Final check after last sleep — avoids off-by-one false-negative
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

device_name_for_udid() {
  local udid="${1}"
  simctl list devices available | awk -F '[()]' -v udid="${udid}" '
    $0 ~ udid {
      name=$1
      sub(/^[[:space:]]+/, "", name)
      sub(/[[:space:]]+$/, "", name)
      print name
      exit
    }
  '
}

wait_for_log_pattern() {
  local pattern="${1}"
  local timeout_seconds="${2}"
  local log_file="${3}"

  local started_at
  started_at="$(date +%s)"

  while true; do
    if [[ -f "${log_file}" ]] && grep -qE "${pattern}" "${log_file}"; then
      echo "$(( $(date +%s) - started_at ))"
      return 0
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      echo "$(( $(date +%s) - started_at ))"
      return 1
    fi

    sleep 0.5
  done
}

