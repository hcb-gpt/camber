# Redline Assistant Harness

Location:

- `/Users/chadbarlow/gh/hcb-gpt/camber/scripts/redline-assistant-winship-harness.sh`

Purpose:

- Runs two golden prompts derived from the superintendent UX pack:
  1. `tell me about permar`
  2. `whos at hurley tomorrow`
- Uses non-brittle string checks instead of exact phrase matching:
  - No DB-dump tokens (`UTC`, `inbound`, `outbound`, `interaction`, ISO timestamps).
  - Has a next-step phrase (`Next:`, `Want me to`, or `I can`).
  - Uses human-time phrasing (`today`, `tomorrow`, `yesterday`, `this morning`, `3 days ago`, etc.).
  - Meets default word cap (`<= 200` words).
- Captures request IDs + assistant-context contract metadata from response headers.
- Stores raw SSE + parsed text artifacts in `artifacts/redline_assistant_harness/<timestamp>/`.

Usage:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber
./scripts/redline-assistant-winship-harness.sh
```

Optional environment overrides:

- `REDLINE_ASSISTANT_URL` (direct function URL)
- `SUPABASE_URL` (base URL used to derive function URL)
- `SUPABASE_ANON_KEY` (if function auth is enabled)
- `OUT_DIR` (artifact output directory)
