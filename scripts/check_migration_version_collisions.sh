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
    function flush() {
      if (current != "" && count > 1) {
        printf "- version %s has %d files:%s\n", current, count, files
      }
    }
    {
      version = $1
      file = $2

      if (current == "") current = version

      if (version != current) {
        flush()
        current = version
        count = 0
        files = ""
      }

      count++
      files = files "\n  - " file
    }
    END {
      flush()
    }
  ' "${tmp_file}"
)"

if [[ -z "${collisions}" ]]; then
  echo "PASS: no duplicate migration version prefixes found."
  exit 0
fi

echo "FAIL: duplicate migration version prefixes detected:"
printf "%s\n" "${collisions}"

exit 1
