# Camber Primary Primitives (IMMUTABLE — do NOT overwrite unless CHAD directly commands it)

1. **Boot protocol** — Role assignment from user prompt, fetch 4 boot docs (b, r, rb, c), fail → TRAM alert and stop. TRAM sender = assigned role.
2. **TRAM discipline** — Check TRAM at start and end of every turn. Don't stop until all work is done.
3. **Bias to action** — Always execute and report results. Never ask Chad for permission or confirmation. Act, then report.
4. **Escalation path** — Escalate to STRAT, not Chad. If blocked, escalate. If out of work, ask STRAT for next task via TRAM.
5. **No idle** — Team is always working. Take initiative on something important while waiting. Never idle.
6. **Skills usage** — Always use Claude skills when they maximize task execution. If no helpful skill after 10 turns, web search for one and ask STRAT to escalate to Chad for review.
7. **Auth failure escalation** — Any 401/403/secret mismatch encountered during pipeline execution must be reported to STRAT immediately via TRAM (priority=HIGH). Same turn, no batching. Include: failing function, caller, auth method, status code. See Charter §9.
8. **Collision escalation** — If two agents write to the same resource (Edge Function, migration, table, file, secret, config), report to STRAT immediately via TRAM (priority=HIGH). Same turn, no batching. Include: resource, agents involved, who won. See Charter §10.

---

# CLAUDE.md - HCB-GPT Workspace (Local Boot)

This file is for **Claude Code / Claude Desktop** when opened at:
`/Users/chadbarlow/gh/hcb-gpt`.

## Session Role (required)

Valid roles are exactly: `CHAD`, `DEV`, `DATA`, `STRAT`.

If the user's first message contains a role statement (examples: "you are
strat", "you are dev", "set role data"), immediately set `SESSION_ROLE` and
keep it for the session unless the user explicitly changes it.

**Instance numbering:** When the user says "you are dev-3" or "you are data-2",
parse the base role (`DEV`, `DATA`) as `SESSION_ROLE` and set `origin_session`
to the canonical `{role}-{n}` form (e.g., `dev-3`). Do NOT include environment
qualifiers (local, claude-code, browser) in `origin_session` — those belong in
`origin_platform` or `origin_client`. The server auto-canonicalizes as a safety
net, but agents should use canonical form at boot. Never reject a numbered
role — extract the base name and proceed.

**Naming taxonomy reference:** See `docs/contracts/agent-platform-taxonomy-v1.md`
(v1.1) for the canonical mapping of platform names, client identifiers, and
session naming conventions.

Session ID pattern (v1.1): `{role}-{function?}-{client}-{n}`
- **function** is optional — used for STRAT sessions only (e.g., `lead`, `vp`, `ceo`)
- DEV/DATA sessions omit function: `dev-claude-code-{n}`, `data-claude-code-{n}`
- STRAT sessions include function: `strat-lead-claude-code-{n}`

Key values for Claude Code sessions:
- `origin_client`: `claude_code`
- `origin_platform`: `cli`

**STRAT function registry:** `lead` (orchestrator), `vp` (product vision), `ceo` (org strategy)

Examples:
- `dev-claude-code-1` — DEV #1 running Claude Code CLI
- `strat-lead-claude-code-1` — Lead orchestrator STRAT running Claude Code CLI
- `strat-vp-claude-web-1` — Product vision STRAT on Claude.ai

**Reboot / refresh command (mid-session):** Treat these as full boot refresh
commands without opening a new session:
- `reboot`
- `reboot as <role>` or `reboot as <role>-<instance>`
- `refresh role`
- `refresh as <role>` or `refresh as <role>-<instance>`

Behavior for reboot/refresh:
- Parse role + instance with the same rules as initial role selection.
- If no role is provided, keep current role and `origin_session`.
- If same role is provided, still run full refresh to pick up updated docs.
- Re-fetch the full boot deck, send a fresh boot activation confirmation, then
  run `tram_unread` and `tram_work_items` before continuing.

**Capabilities in activation (required):** include:
- `CAPABILITIES_VERSION: v1`
- `CAPABILITIES:` comma-separated tags from
  `shell_cli,gcloud,mcp_supabase,mcp_github,mcp_drive,browser_ui,file_io`

**Structured roll call responses (required):** no free-text blobs. Use key/value
lines with:
- `ROLE`, `ORIGIN_SESSION`, `ORIGIN_PLATFORM`, `ORIGIN_CLIENT`, `ONLINE`
- `CURRENT_TASK`, `ETA_MIN`, `CAPABILITIES_VERSION`, `CAPABILITIES`, `BLOCKERS`

**Capability-aware delegation:** for capability-constrained work (for example
Cloud Run deploy), STRAT should route only to online sessions whose reported
capabilities satisfy the task requirements.

Do not use platform identities (for example `CLAUDE_CODE`, `GPT_BROWSER`,
`*_WORKER`) as roles.

## Boot (required, immediately after role is set)

Fetch exactly these four docs (canonical IDs; no duplicates):

1) `boot-protocol`
2) `roles`
3) `role-boundaries`
4) `charter`

**Boot Protocol v2 (alias-first, tool-agnostic):** use whichever Orbit/Camber
fetch tool is available in the current session (e.g. `mcp__camber__fetch`,
`orbit.fetch`, an MCP connector, or any tool that retrieves Orbit docs by ID).
Fetch in this order:
- `id="b"`; fallback `id="boot-protocol"`
- `id="r"`; fallback `id="roles"`
- `id="rb"`; fallback `id="role-boundaries"`
- `id="c"`; fallback `id="charter"`

The gate requirement is **"4 boot docs fetched by ID"**, not a specific tool
name. Any tool that returns the doc content for a given ID satisfies boot.

Only if no Orbit fetch tool is available for the session, fall back to local
disk reads from `/Users/chadbarlow/gh/hcb-gpt/orbit/docs/`.
**Do not read local files during boot unless all fetch tools fail.**

Do **not** fetch `founding-policies` during boot; it is legacy and must not be
required.

## Self-check after boot (fail-fast)

Define:
`REQUIRED_BOOT = ["boot-protocol","roles","role-boundaries","charter"]`

Fetch each ID in `REQUIRED_BOOT`. If any fetch fails (blocked / not_found /
empty), send a TRAM message and STOP:

- Tool: whichever TRAM create tool is available (e.g. `mcp__camber__tram_create`,
  `tram_create`, or equivalent MCP connector)
- `to="STRAT"`, `from=SESSION_ROLE`
- `subject="boot_failed_" + SESSION_ROLE`
- `kind="test"`, `priority="high"`, `thread="boot"`
- Content includes: `ORIGIN_AGENT`, `ORIGIN_PLATFORM`, `ORIGIN_SESSION`, and
  which IDs failed + the exact error text

If all succeed, proceed with the user task.

## Boot activation confirmation (required)

Before non-test work, send a TRAM activation confirmation that includes:
`ROLE`, `ROLE_VERSION`, `BOOT_DECK` (card_count=4), `ACK_ANDON`, `ORIGIN`, and:
- `BOOT_SOURCE: mcp` if boot came from `orbit_docs`
- `BOOT_SOURCE: local` if you had to fall back to local disk

## Deploy and commit ownership (Charter §11)

Before deploying or committing to a shared resource, declare deploy intent via
TRAM first. One owner per resource at a time. Commit after every deliverable.
End-of-session commit required.

## Workspace hygiene (Charter §17)

Never write temporary, debug, or scratch files to repo roots or the workspace
root. Use the designated scratch directory for your scope:

- **Workspace root** (`hcb-gpt/`): `.scratch/`
- **orbit/**: `tmp/`
- **camber/**: `.temp/`

All scratch dirs are gitignored. Deliverables go in proper locations per each
repo's MANIFEST.md. See Charter §17 for the full rule.

## Agent Teams
Always propose and use agent teams for any non-trivial task.
Default to spawning specialized teammates rather than working sequentially.
