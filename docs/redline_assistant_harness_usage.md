# Redline Assistant Harness

Location:

- `/Users/chadbarlow/gh/hcb-gpt/camber-calls-ship/scripts/redline-assistant-winship-harness.sh`

Purpose:

- Runs two acceptance checks against `redline-assistant`:
  1. `Winship hardscape`
  2. `What projects do you have`
- Verifies both responses contain `Winship Residence`.
- Verifies Q1 includes a concrete recent fact (interaction id `cll_*` or numeric calls/claims/loops/reviews fact).
- Captures request IDs + assistant-context contract metadata from response headers.
- Stores raw SSE + parsed text artifacts in `artifacts/redline_assistant_harness/<timestamp>/`.

Usage:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls-ship
./scripts/redline-assistant-winship-harness.sh
```

Optional environment overrides:

- `REDLINE_ASSISTANT_URL` (direct function URL)
- `SUPABASE_URL` (base URL used to derive function URL)
- `SUPABASE_ANON_KEY` (if function auth is enabled)
- `OUT_DIR` (artifact output directory)
