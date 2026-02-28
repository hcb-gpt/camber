#!/usr/bin/env bash
# synthetics_config.sh — Read / update the consolidated synthetics config knob.
#
# Usage:
#   ./scripts/synthetics_config.sh              # print current config as JSON
#   ./scripts/synthetics_config.sh --get <key>  # print one key's value
#   ./scripts/synthetics_config.sh --set key=value [key=value ...]
#   ./scripts/synthetics_config.sh --help
#
# Requires: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (or source ~/.camber/credentials.env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load credentials if available
if [[ -f "$HOME/.camber/credentials.env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.camber/credentials.env"
fi

SUPABASE_URL="${SUPABASE_URL:?SUPABASE_URL not set}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY not set}"

CONFIG_SCOPE="synthetics"
CONFIG_KEY="SYNTHETICS_CONFIG_V1"

usage() {
  cat <<'EOF'
synthetics_config.sh — Consolidated synthetics config knob

Usage:
  synthetics_config.sh              Print current config as JSON
  synthetics_config.sh --get <key>  Print one key's value (e.g. --get enabled)
  synthetics_config.sh --set k=v    Update one or more keys (e.g. --set enabled=true seed=99)
  synthetics_config.sh --help       Show this help

Config keys:
  enabled                 (bool)   Master on/off switch
  scenario_ids            (array)  JSON array of scenario IDs to run
  injection_rate          (text)   Cron expression for injection schedule
  seed                    (int)    Deterministic seed for reproducible runs
  namespace               (text)   'prod' or 'synthetic' — controls write target
  log_level               (text)   'debug', 'info', or 'warn'
  artifact_retention_days (int)    How many days to keep artifacts

Environment:
  SUPABASE_URL                 (required)
  SUPABASE_SERVICE_ROLE_KEY    (required)
EOF
  exit 0
}

fetch_config() {
  curl -sf \
    "${SUPABASE_URL}/rest/v1/pipeline_config?scope=eq.${CONFIG_SCOPE}&config_key=eq.${CONFIG_KEY}&select=config_value" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Accept: application/vnd.pgrst.object+json" \
  | jq -r '.config_value'
}

update_config() {
  local patch="$1"
  # Read current, merge, write back
  local current
  current="$(fetch_config)"
  if [[ -z "$current" || "$current" == "null" ]]; then
    echo "ERROR: Could not read current config" >&2
    exit 1
  fi

  local merged
  merged="$(echo "$current" | jq --argjson p "$patch" '. * $p')"

  curl -sf -X PATCH \
    "${SUPABASE_URL}/rest/v1/pipeline_config?scope=eq.${CONFIG_SCOPE}&config_key=eq.${CONFIG_KEY}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "{\"config_value\": ${merged}, \"updated_by\": \"synthetics_config.sh\", \"updated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  | jq -r '.config_value'
}

# --- Main ---

if [[ $# -eq 0 ]]; then
  fetch_config | jq .
  exit 0
fi

case "$1" in
  --help|-h)
    usage
    ;;
  --get)
    [[ $# -lt 2 ]] && { echo "ERROR: --get requires a key name" >&2; exit 1; }
    fetch_config | jq -r ".${2}"
    ;;
  --set)
    shift
    [[ $# -eq 0 ]] && { echo "ERROR: --set requires key=value pairs" >&2; exit 1; }
    patch="{}"
    for kv in "$@"; do
      key="${kv%%=*}"
      val="${kv#*=}"
      # Detect type: bool, int, json array, or string
      if [[ "$val" == "true" || "$val" == "false" ]]; then
        patch="$(echo "$patch" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v')"
      elif [[ "$val" =~ ^[0-9]+$ ]]; then
        patch="$(echo "$patch" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v')"
      elif [[ "$val" == \[* ]]; then
        patch="$(echo "$patch" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v')"
      else
        patch="$(echo "$patch" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')"
      fi
    done
    echo "Updating config..."
    update_config "$patch"
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    ;;
esac
