#!/usr/bin/env bash
set -euo pipefail

# Smoke test for morning-manifest-ui JSON and HTML modes.
# Requirements:
# - SUPABASE_URL
# - SUPABASE_SERVICE_ROLE_KEY (or a valid Bearer JWT)
#
# Usage:
#   scripts/morning_manifest_ui_smoke.sh
#   LIMIT=25 scripts/morning_manifest_ui_smoke.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/scripts/load-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/load-env.sh" >/dev/null 2>&1 || true
fi

SUPABASE_URL="${SUPABASE_URL:-}"
BEARER_TOKEN="${BEARER_TOKEN:-${SUPABASE_SERVICE_ROLE_KEY:-}}"
LIMIT="${LIMIT:-50}"

if [[ -z "${SUPABASE_URL}" ]]; then
  echo "ERROR: SUPABASE_URL is required" >&2
  exit 1
fi

if [[ -z "${BEARER_TOKEN}" ]]; then
  echo "ERROR: BEARER_TOKEN or SUPABASE_SERVICE_ROLE_KEY is required" >&2
  exit 1
fi

OUT_DIR="${ROOT_DIR}/artifacts/morning_manifest_ui_smoke/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT_DIR}"

JSON_URL="${SUPABASE_URL}/functions/v1/morning-manifest-ui?limit=${LIMIT}&format=json"
HTML_URL="${SUPABASE_URL}/functions/v1/morning-manifest-ui?limit=${LIMIT}&format=html"

JSON_BODY="${OUT_DIR}/json_body.txt"
JSON_HEADERS="${OUT_DIR}/json_headers.txt"
HTML_BODY="${OUT_DIR}/html_body.txt"
HTML_HEADERS="${OUT_DIR}/html_headers.txt"

json_status="$(
  curl -sS "${JSON_URL}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Accept: application/json" \
    -D "${JSON_HEADERS}" \
    -o "${JSON_BODY}" \
    -w "%{http_code}"
)"

html_status="$(
  curl -sS "${HTML_URL}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Accept: text/html" \
    -D "${HTML_HEADERS}" \
    -o "${HTML_BODY}" \
    -w "%{http_code}"
)"

if [[ "${json_status}" != "200" ]]; then
  echo "FAIL: JSON status=${json_status} (expected 200)" >&2
  exit 1
fi

if [[ "${html_status}" != "200" ]]; then
  echo "FAIL: HTML status=${html_status} (expected 200)" >&2
  exit 1
fi

if ! grep -q '"ok"[[:space:]]*:[[:space:]]*true' "${JSON_BODY}"; then
  echo "FAIL: JSON body missing ok=true marker" >&2
  exit 1
fi

if ! grep -qi '^content-type:.*application/json' "${JSON_HEADERS}"; then
  echo "FAIL: JSON response missing application/json content-type" >&2
  exit 1
fi

if ! grep -q "<title>Morning Manifest Dashboard</title>" "${HTML_BODY}"; then
  echo "FAIL: HTML body missing dashboard title" >&2
  exit 1
fi

if ! grep -qi '^content-type:.*text/html' "${HTML_HEADERS}"; then
  echo "FAIL: HTML response missing text/html content-type" >&2
  exit 1
fi

{
  echo "PASS: morning-manifest-ui smoke"
  echo "json_status=${json_status}"
  echo "html_status=${html_status}"
  echo "out_dir=${OUT_DIR}"
} | tee "${OUT_DIR}/summary.txt"
