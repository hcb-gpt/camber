#!/usr/bin/env bash
set -euo pipefail

# Detect duplicate migration version prefixes in supabase/migrations.
#
# Usage:
#   scripts/check_migration_version_collisions.sh
#   scripts/check_migration_version_collisions.sh --help
# Exit codes:
#   0 = no collisions
#   1 = collisions found
#   2 = invalid arguments

print_help() {
  cat <<'EOF'
Usage: scripts/check_migration_version_collisions.sh [--help|-h]

Detect duplicate migration version prefixes in supabase/migrations.
Exit codes:
  0 = no collisions
  1 = collisions found
  2 = invalid arguments
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "ERROR: unknown argument: $1" >&2
  print_help >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="${ROOT_DIR}/supabase/migrations"

if [[ ! -d "${MIG_DIR}" ]]; then
  echo "ERROR: migration directory not found: ${MIG_DIR}" >&2
  exit 2
fi

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

find "${MIG_DIR}" -maxdepth 1 -type f -name '*.sql' -print0 \
  | xargs -0 -n1 basename \
  | awk -F'_' '{print $1 "|" $0}' \
  | sort > "${tmp_file}"

collisions="$(
  awk -F'|' '
    {
      files[$1] = files[$1] "\n  - " $2
      count[$1]++
    }
    END {
      for (v in count) {
        if (count[v] > 1) {
          print v "|" count[v] files[v]
        }
      }
    }
  ' "${tmp_file}" | sort
)"

if [[ -z "${collisions}" ]]; then
  echo "PASS: no duplicate migration version prefixes found."
  exit 0
fi

echo "FAIL: duplicate migration version prefixes detected:"
echo "${collisions}" | while IFS='|' read -r version n rest; do
  echo "- version ${version} has ${n} files:${rest}"
done

exit 1
