#!/usr/bin/env bash
set -euo pipefail

# journal_embed_backfill_probe.sh
# Deterministic probe for journal-embed-backfill response contract.
# Verifies stage-level metrics fields are present in dry-run mode.
#
# Usage:
#   ./scripts/journal_embed_backfill_probe.sh
#   ./scripts/journal_embed_backfill_probe.sh --project-id <uuid> --limit 20
#   ./scripts/journal_embed_backfill_probe.sh --induce-failure

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load-env.sh"

PROJECT_ID=""
LIMIT="10"
INDUCE_FAILURE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-10}"
      shift 2
      ;;
    --induce-failure)
      INDUCE_FAILURE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--project-id <uuid>] [--limit <n>] [--induce-failure]"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

for var in SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY EDGE_SHARED_SECRET; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Missing required env var: ${var}" >&2
    exit 2
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required." >&2
  exit 2
fi

if [[ "${INDUCE_FAILURE}" == "true" ]]; then
  payload=$(jq -n \
    --argjson dry_run false \
    --argjson limit 1 \
    --argjson batch_size 1 \
    --arg model "text-embedding-3-small-NONEXISTENT" \
    '{dry_run: $dry_run, limit: $limit, batch_size: $batch_size, model: $model}')
else
  payload=$(jq -n \
    --argjson dry_run true \
    --argjson limit "${LIMIT}" \
    --arg project_id "${PROJECT_ID}" \
    '{dry_run: $dry_run, limit: $limit} + (if $project_id != "" then {project_id: $project_id} else {} end)')
fi

response=$(curl -sS -X POST "${SUPABASE_URL}/functions/v1/journal-embed-backfill" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
  -d "${payload}")

ok=$(jq -r '.ok // false' <<<"${response}")
if [[ "${ok}" != "true" ]]; then
  echo "PROBE_FAIL journal_embed_backfill ok=false response=${response}"
  exit 1
fi

jq -e '.request_id | strings | length > 0' <<<"${response}" >/dev/null
jq -e '.stage_metrics.selected_rows >= 0' <<<"${response}" >/dev/null
jq -e '.stage_metrics.candidate_rows >= 0' <<<"${response}" >/dev/null
jq -e '.stage_metrics.prepared_rows >= 0' <<<"${response}" >/dev/null
jq -e '.stage_metrics.batch_count >= 0' <<<"${response}" >/dev/null
jq -e '.stage_metrics.update_attempted >= 0' <<<"${response}" >/dev/null

if [[ "${INDUCE_FAILURE}" == "true" ]]; then
  jq -e '.failed_count > 0' <<<"${response}" >/dev/null
  jq -e '.zero_write_warning.warning == true' <<<"${response}" >/dev/null
  echo "PROBE_OK journal_embed_backfill failure_mode request_id=$(jq -r '.request_id' <<<"${response}") failed=$(jq -r '.failed_count' <<<"${response}") warning=true"
else
  echo "PROBE_OK journal_embed_backfill dry_run request_id=$(jq -r '.request_id' <<<"${response}") selected=$(jq -r '.selected_rows // 0' <<<"${response}") prepared=$(jq -r '.prepared_rows // 0' <<<"${response}")"
fi
