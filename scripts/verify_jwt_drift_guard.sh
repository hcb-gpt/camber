#!/usr/bin/env bash
# verify_jwt_drift_guard.sh
# Fails fast when deployed Edge Function verify_jwt flags drift from repo source of truth.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/verify_jwt_drift_guard.sh --project-ref <ref> [--functions <csv>] [--output table|json]

Options:
  --project-ref <ref>   Supabase project ref (or set SUPABASE_PROJECT_ID).
  --functions <csv>     Comma-separated function slugs to check.
                        Defaults to all local supabase/functions/* (excluding _shared).
  --output <mode>       table (default) or json.
  -h, --help            Show this help.

Behavior:
  expected verify_jwt precedence:
    1) supabase/functions/<fn>/config.toml (verify_jwt)
    2) supabase/config.toml [functions.<fn>].verify_jwt
    3) default true (Supabase default)
EOF
}

PROJECT_REF="${SUPABASE_PROJECT_ID:-}"
FUNCTIONS_CSV=""
OUTPUT_MODE="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --functions)
      FUNCTIONS_CSV="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${PROJECT_REF}" ]]; then
  echo "ERROR: --project-ref is required (or set SUPABASE_PROJECT_ID)." >&2
  exit 2
fi

if [[ "${OUTPUT_MODE}" != "table" && "${OUTPUT_MODE}" != "json" ]]; then
  echo "ERROR: --output must be 'table' or 'json'." >&2
  exit 2
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "ERROR: supabase CLI is required." >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

declare -a TARGETS=()
if [[ -n "${FUNCTIONS_CSV}" ]]; then
  while IFS= read -r fn; do
    [[ -n "${fn}" ]] && TARGETS+=("${fn}")
  done < <(printf '%s' "${FUNCTIONS_CSV}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u)
else
  while IFS= read -r fn; do
    TARGETS+=("${fn}")
  done < <(find "${REPO_ROOT}/supabase/functions" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | grep -Ev '^_shared$')
fi

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "ERROR: no target functions resolved." >&2
  exit 2
fi

LIVE_JSON="$(mktemp)"
trap 'rm -f "${LIVE_JSON}"' EXIT

supabase functions list --project-ref "${PROJECT_REF}" --output json > "${LIVE_JSON}"

python3 - "${REPO_ROOT}" "${LIVE_JSON}" "${OUTPUT_MODE}" "${TARGETS[@]}" <<'PY'
import json
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore


def load_toml(path: pathlib.Path) -> dict:
    if not path.exists():
        return {}
    return tomllib.loads(path.read_text())


def as_bool(value):
    return value if isinstance(value, bool) else None


def bool_str(value):
    if value is None:
        return "-"
    return "true" if value else "false"


repo_root = pathlib.Path(sys.argv[1])
live_json_path = pathlib.Path(sys.argv[2])
output_mode = sys.argv[3]
targets = sys.argv[4:]

project_cfg = load_toml(repo_root / "supabase" / "config.toml")
project_functions = project_cfg.get("functions")
if not isinstance(project_functions, dict):
    project_functions = {}

live_rows = json.loads(live_json_path.read_text())
live_map = {}
for row in live_rows:
    slug = row.get("slug") or row.get("name")
    if slug:
        live_map[slug] = row

results = []
has_mismatch = False
for fn in targets:
    expected = True
    source = "default(true)"
    has_contract = False
    fn_dir_exists = (repo_root / "supabase" / "functions" / fn).exists()

    fn_cfg_path = repo_root / "supabase" / "functions" / fn / "config.toml"
    fn_cfg = load_toml(fn_cfg_path)
    fn_expected = as_bool(fn_cfg.get("verify_jwt"))
    if fn_expected is None:
        fn_section = fn_cfg.get("function")
        if isinstance(fn_section, dict):
            fn_expected = as_bool(fn_section.get("verify_jwt"))
    if fn_expected is not None:
        expected = fn_expected
        source = str(fn_cfg_path.relative_to(repo_root))
        has_contract = True
    else:
        entry = project_functions.get(fn)
        if isinstance(entry, dict):
            project_expected = as_bool(entry.get("verify_jwt"))
            if project_expected is not None:
                expected = project_expected
                source = "supabase/config.toml"
                has_contract = True

    if (not has_contract) and (not fn_dir_exists):
        expected = None
        source = "missing_local_contract"

    live = None
    version = None
    status = "OK"
    live_entry = live_map.get(fn)
    if live_entry is None:
        status = "MISSING_LIVE"
        has_mismatch = True
    else:
        live = as_bool(live_entry.get("verify_jwt"))
        version = live_entry.get("version")
        if live is None:
            status = "MISSING_FIELD"
            has_mismatch = True
        elif expected is None:
            status = "NO_CONTRACT"
            has_mismatch = True
        elif live != expected:
            status = "DRIFT"
            has_mismatch = True

    results.append(
        {
            "function": fn,
            "expected_verify_jwt": expected,
            "live_verify_jwt": live,
            "source": source,
            "status": status,
            "version": version,
        }
    )

if output_mode == "json":
    print(json.dumps(results, indent=2))
else:
    print("verify_jwt contract audit")
    print("function\texpected\tlive\tsource\tstatus\tversion")
    ok_count = 0
    for row in results:
        if row["status"] == "OK":
            ok_count += 1
        print(
            f"{row['function']}\t"
            f"{bool_str(row['expected_verify_jwt'])}\t"
            f"{bool_str(row['live_verify_jwt'])}\t"
            f"{row['source']}\t"
            f"{row['status']}\t"
            f"{row['version'] if row['version'] is not None else '-'}"
        )
    print(f"summary: {ok_count}/{len(results)} functions in-contract")

if has_mismatch:
    sys.exit(1)
PY
