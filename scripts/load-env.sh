#!/bin/bash
# Beside v3.8 Environment Loader
# Sources credentials for scripts that need them
# Usage: source scripts/load-env.sh

# Idempotent: avoid re-loading in the same shell
if [ -n "${CAMBER_CREDS_LOADED:-}" ]; then
    if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] && [ -n "${EDGE_SHARED_SECRET:-}" ]; then
        return 0 2>/dev/null || exit 0
    fi
fi

# Prefer central loader (Keychain-aware)
if [ -f "${HOME:-}/.camber/load-credentials.sh" ]; then
    # shellcheck source=/dev/null
    source "${HOME:-}/.camber/load-credentials.sh" 2>/dev/null || true
fi

# Fallback to central file if still missing
if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ] || [ -z "${EDGE_SHARED_SECRET:-}" ]; then
  if [ -f "${HOME:-}/.camber/credentials.env" ]; then
      set -a
      source "${HOME:-}/.camber/credentials.env"
      set +a
      echo "✅ Loaded credentials from ~/.camber/credentials.env"
# Fallback to local .env.local
  elif [ -f "$(git rev-parse --show-toplevel)/.env.local" ]; then
      set -a
      source "$(git rev-parse --show-toplevel)/.env.local"
      set +a
      echo "✅ Loaded credentials from .env.local"
  else
      echo "❌ No credentials found!"
      echo "   Expected: ~/.camber/credentials.env"
      echo "   Or: $(git rev-parse --show-toplevel)/.env.local"
      echo ""
      echo "   Setup: ~/.camber/keychain-import.sh (preferred)"
      echo "   Or: cp ~/Desktop/env\ secrets.txt ~/.camber/credentials.env"
      exit 1
  fi
fi

# Verify required vars
MISSING=""
[ -z "${SUPABASE_URL:-}" ] && MISSING="$MISSING SUPABASE_URL"
[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ] && MISSING="$MISSING SUPABASE_SERVICE_ROLE_KEY"
[ -z "${EDGE_SHARED_SECRET:-}" ] && MISSING="$MISSING EDGE_SHARED_SECRET"

if [ -n "$MISSING" ]; then
    echo "⚠️  Missing required vars:$MISSING"
    exit 1
fi

# Mark successful load for this shell
export CAMBER_CREDS_LOADED=1

# Export Supabase CLI token if available
if [ -n "${CLI:-}" ]; then
    export SUPABASE_ACCESS_TOKEN="${CLI}"
fi
