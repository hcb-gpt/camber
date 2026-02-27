#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/redline_perf_probe.sh --base-url <url> [--runs N] [--contact-id <uuid>] [--out <path>]

Examples:
  scripts/redline_perf_probe.sh --base-url "https://<project>.supabase.co/functions/v1/redline-thread"
  scripts/redline_perf_probe.sh --base-url "https://<project>.supabase.co/functions/v1/redline-thread" --runs 20
EOF
}

BASE_URL=""
RUNS=15
CONTACT_ID=""
OUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --contact-id)
      CONTACT_ID="${2:-}"
      shift 2
      ;;
    --out)
      OUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "[FAIL] --base-url is required." >&2
  usage >&2
  exit 1
fi

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "[FAIL] --runs must be a positive integer." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[FAIL] jq is required." >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUT_PATH" ]]; then
  OUT_PATH="/tmp/redline_perf_probe_${TS}.json"
fi

TMP_JSONL="$(mktemp)"
trap 'rm -f "$TMP_JSONL"' EXIT

if [[ -z "$CONTACT_ID" ]]; then
  CONTACT_ID="$(
    curl -sS "${BASE_URL}?action=contacts" \
      | jq -r '.contacts[0].contact_id // empty'
  )"
fi

if [[ -z "$CONTACT_ID" ]]; then
  echo "[FAIL] Could not determine contact_id (pass --contact-id explicitly)." >&2
  exit 1
fi

probe() {
  local endpoint="$1"
  local expected="$2"
  local url="$3"

  for i in $(seq 1 "$RUNS"); do
    local hdr body meta
    hdr="$(mktemp)"
    body="$(mktemp)"
    meta="$(curl -sS -o "$body" -D "$hdr" \
      -w "{\"http_code\":%{http_code},\"time_total\":%{time_total},\"time_starttransfer\":%{time_starttransfer},\"size_download\":%{size_download}}" \
      "$url")"

    local content_type body_prefix body_is_html
    content_type="$(
      awk 'BEGIN{IGNORECASE=1} /^content-type:/{print tolower($2); exit}' "$hdr" \
        | tr -d '\r'
    )"
    body_prefix="$(head -c 24 "$body" | tr '\n' ' ')"
    if echo "$body_prefix" | grep -qi '^<!doctype html>'; then
      body_is_html=true
    else
      body_is_html=false
    fi

    jq -cn \
      --arg endpoint "$endpoint" \
      --arg expected "$expected" \
      --arg url "$url" \
      --argjson run "$i" \
      --arg content_type "${content_type:-unknown}" \
      --arg body_prefix "$body_prefix" \
      --argjson body_is_html "$body_is_html" \
      --argjson m "$meta" \
      '{
        endpoint: $endpoint,
        expected: $expected,
        url: $url,
        run: $run,
        http_code: $m.http_code,
        time_total: $m.time_total,
        time_starttransfer: $m.time_starttransfer,
        size_download: $m.size_download,
        content_type: $content_type,
        body_prefix: $body_prefix,
        body_is_html: $body_is_html
      }' >> "$TMP_JSONL"

    rm -f "$hdr" "$body"
  done
}

probe "html_shell" "html" "$BASE_URL"
probe "projects" "json" "${BASE_URL}?action=projects"
probe "sanity" "json" "${BASE_URL}?action=sanity"
probe "thread_first_contact" "json" "${BASE_URL}?contact_id=${CONTACT_ID}&limit=20&offset=0"

jq -s \
  --arg measured_at_utc "$TS" \
  --arg base_url "$BASE_URL" \
  --arg contact_id "$CONTACT_ID" \
  --arg runs "$RUNS" \
  '
  def pct(vals; p):
    if (vals|length)==0 then null
    else (vals|sort) as $s | $s[((((($s|length)-1) * p))|floor)]
    end;
  def contract_ok(row):
    if row.expected == "json" then
      (row.http_code == 200 and (row.content_type | startswith("application/json")) and (row.body_is_html | not))
    else
      (row.http_code == 200 and row.body_is_html)
    end;
  def summarize(rows):
    {
      runs: (rows|length),
      status_codes: (rows|map(.http_code)|unique),
      content_types: (rows|map(.content_type)|unique),
      avg_time_total: ((rows|map(.time_total)|add)/(rows|length)),
      p50_time_total: pct((rows|map(.time_total)); 0.50),
      p95_time_total: pct((rows|map(.time_total)); 0.95),
      avg_ttfb: ((rows|map(.time_starttransfer)|add)/(rows|length)),
      p95_ttfb: pct((rows|map(.time_starttransfer)); 0.95),
      contract_failures: (rows|map(select(contract_ok(.)|not))|length),
      contract_ok: (rows|all(contract_ok(.)))
    };
  {
    measured_at_utc: $measured_at_utc,
    base_url: $base_url,
    contact_id: $contact_id,
    runs_per_endpoint: ($runs|tonumber),
    endpoints: (group_by(.endpoint) | map({key: .[0].endpoint, value: summarize(.)}) | from_entries),
    contract_ok_all: (all(contract_ok(.))),
    raw: .
  }
  ' "$TMP_JSONL" > "$OUT_PATH"

echo "[DONE] Wrote probe report: $OUT_PATH"
echo
jq -r '
  .endpoints
  | to_entries[]
  | "- \(.key): p95=\(.value.p95_time_total)s, p95_ttfb=\(.value.p95_ttfb)s, contract_ok=\(.value.contract_ok), content_types=\(.value.content_types|join(","))"
' "$OUT_PATH"
echo "contract_ok_all=$(jq -r '.contract_ok_all' "$OUT_PATH")"
