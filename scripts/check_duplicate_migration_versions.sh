#!/usr/bin/env bash
set -euo pipefail

# Detect duplicate version prefixes in Supabase migration filenames.
# Exits non-zero when duplicates exist so this can be used as a CI/preflight gate.

root_dir="${1:-.}"
migrations_dir="${root_dir%/}/supabase/migrations"

if [[ ! -d "$migrations_dir" ]]; then
  echo "ERROR: migrations directory not found: $migrations_dir" >&2
  exit 2
fi

file_count="$(find "$migrations_dir" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')"

if [[ "$file_count" -eq 0 ]]; then
  echo "OK: no migration files found in $migrations_dir"
  exit 0
fi

dupes="$(
  find "$migrations_dir" -maxdepth 1 -type f -name '*.sql' \
    | xargs -n1 basename \
    | cut -d_ -f1 \
    | sort \
    | uniq -cd
)"

if [[ -n "$dupes" ]]; then
  echo "FAIL: duplicate migration versions detected:"
  echo "$dupes" | sed 's/^ *//'
  echo
  while read -r count version; do
    [[ -z "${version:-}" ]] && continue
    echo "version $version files:"
    find "$migrations_dir" -maxdepth 1 -type f -name "${version}_*.sql" | sort | sed 's/^/  - /'
  done <<< "$dupes"
  exit 1
fi

echo "OK: no duplicate migration versions detected in $migrations_dir"
