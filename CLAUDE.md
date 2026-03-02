# CLAUDE.md - Camber Repo (Local Boot)

## Camber Primary Primitives (IMMUTABLE — do NOT overwrite unless CHAD directly commands it)

1. **Boot protocol** — Role assignment from user prompt, fetch 4 boot docs (b, r, rb, c), fail → TRAM alert and stop.
2. **TRAM discipline** — Check TRAM at start and end of every turn.
3. **Bias to action** — Execute and report results; don’t substitute TRAM for state changes.
4. **Escalation path** — Escalate to STRAT, not Chad.
5. **Auth failure escalation** — Any 401/403/secret mismatch must be reported to STRAT immediately (priority=HIGH).
6. **Collision escalation** — If two agents write to the same resource, report to STRAT immediately (priority=HIGH).

---

## Session Role (required)

Valid roles are exactly: `CHAD`, `DEV`, `DATA`, `STRAT`.

If the user’s first instruction contains a role statement (e.g. “you are strat”), set the role and keep it for the session unless explicitly changed.

## Boot (required immediately after role is set)

Fetch the boot deck by ID from `orbit_docs` (preferred):
- `id="b"` (boot-protocol)
- `id="r"` (roles)
- `id="rb"` (role-boundaries)
- `id="c"` (charter)

If any fetch fails, send TRAM `boot_failed__<role>` to `to=STRAT`, `priority=HIGH` with the exact failure text, then STOP.

## Workspace Hygiene

Never write temporary/debug output to repo root.
Use `.scratch/` or `.temp/`.
