# DATA SQL Access (Canonical)

Primary path for DATA agents:
- Use Supabase MCP `execute_sql` against project `dd619142` (`rjhdwidddtfetbwqolof`).
- This is the canonical route for production query execution and evidence collection.

If `execute_sql` is unavailable in-session:
- Escalate via TRAM to `STRAT` or `DEV` with the exact SQL and expected output.
- Include the exact missing-tool error text in the blocker note.

Local fallback (read-only checks only, not canonical):

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber
scripts/query.sh "select now();"
```

`scripts/query.sh` loads env via `scripts/load-env.sh` and enforces read-only statements (`SELECT`, `WITH`, `EXPLAIN`, `SHOW`).
