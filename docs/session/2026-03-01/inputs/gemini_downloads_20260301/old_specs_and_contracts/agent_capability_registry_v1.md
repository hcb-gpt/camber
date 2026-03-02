# Agent Capability Registry v1 (Platforms, Models, Internal Teams)

Purpose: route work safely and quickly across platforms (Chrome browser, Claude Code desktop/CLI, Codex) by making **hard abilities** and **soft strengths** explicit and verifiable.

This spec is **platform-aware**:
- A **TRAM session** is the only cross-platform routable identity.
- Some platforms (notably **Claude Code CLI**) can spawn **internal agentic teams** (“subagents”) that are **not visible/routable** to other platforms; they must be represented as **metadata on the lead session**, not as separate TRAM sessions.

---

## 1) Definitions (hard)

- **Session**: a TRAM identity `{ROLE, origin_session}`. This is what `FOR_SESSION` targets.
- **Platform family**: the product/runtime (e.g., `claude_code`, `codex`, `chatgpt`, `claude_web`).
- **Platform env**: where it runs (`desktop | cli | browser`).
- **Platform subtype**: mode inside the platform (e.g., Claude desktop `chat | cowork | code`).
- **Internal team (subagents)**: a local-only decomposition inside a *single* session. Only the lead session is routable.

---

## 2) Platform enumeration (v1)

### Claude Code (desktop app)
- **Subtypes:** `chat`, `cowork`, `code`
- **Hard ability envelope:** file + shell access are **permissioned** (must be declared as granted/ask/blocked in profile).
- **When to route:**
  - `cowork` for cross-app orchestration and long-context coordination.
  - `code` for repo changes where the environment is actually granted.

### Claude Code (CLI)
- **Env:** `cli`
- **Hard ability envelope:** can edit files/run commands/create commits *when granted*; must declare permission state.
- **Internal teams:** CLI may spawn subagents under arbitrary names. These are **not visible cross-platform**.
  - Representation rule: list subagents under `INTERNAL_TEAM` in the lead session profile.
  - Routing rule: TRAM always targets the lead `origin_session`; optionally include “please delegate to <subagent-name>” in content.

### Codex (desktop)
- **Env:** `desktop`
- **Hard ability envelope:** typically strong for repo-scale code edits + test loops; permissions must still be declared.

### Browser sessions (Chrome)
- **Env:** `browser`
- **Hard ability envelope:** usually no direct disk/shell; strong at review, UI verification, policy.

---

## 3) Model soft-strength priors (v1)

These are **priors**, not truth. They help routing when hard capabilities match.

- **Anthropic Claude family**
  - Typical strengths: orchestration, instruction-following consistency, long-context synthesis, critique.
- **OpenAI GPT/Codex family**
  - Typical strengths: deep coding/refactors, mechanical transformations, tool-driven debug loops.

Always prefer:
1) **Hard capabilities match** (can actually run the needed tools) over priors.
2) Recent **proof of work** (deploy/migration/test results) over priors.

---

## 4) Hard capability tags (required vocabulary)

### Required v1 tags (activation + profile)
- `shell_cli` — can run terminal commands
- `file_io` — can read/write workspace files
- `gcloud` — can deploy/inspect Cloud Run etc
- `mcp_supabase` — can query/apply migrations via MCP
- `mcp_github` — can read/write GitHub via MCP
- `mcp_drive` — can read/write Drive via MCP
- `browser_ui` — can operate/verify browser UI flows

### Permission state (required)
Hard caps must be split into:
- `HARD_CAPS_POTENTIAL`: what the platform could do if granted permissions
- `HARD_CAPS_GRANTED`: what is currently granted and usable *now*

---

## 5) Capability Profile v1 (copy/paste schema)

Sessions must publish this block on boot and whenever permissions change:

```yaml
CAPABILITY_PROFILE_V1:
  role: <DEV|DATA|STRAT>
  origin_session: <string>
  platform:
    family: <claude_code|codex|chatgpt|claude_web|other>
    env: <desktop|cli|browser>
    subtype: <chat|cowork|code|n/a>
  model:
    provider: <anthropic|openai|other|unknown>
    name: <string|unknown>
  hard_caps:
    granted: [shell_cli, file_io, gcloud, mcp_supabase, mcp_github, mcp_drive, browser_ui]
    potential: [shell_cli, file_io, gcloud, mcp_supabase, mcp_github, mcp_drive, browser_ui]
  permission_state:
    file_io: <granted|ask|blocked>
    shell_cli: <granted|ask|blocked>
    gcloud: <authed|not_authed|n/a>
  soft:
    strengths_top3: [orchestration, deep_coding, debugging]
    limits_top3: [ux, sql, writing]
  internal_team:
    has_internal_subagents: <yes|no>
    team_name: <string>
    members:
      - name: <string>
        focus: <string>
```

---

## 6) Verification protocol (ask, then trust)

1) STRAT issues a `request__capability_profile_v1__<role>__<date>` to each role.
2) Each session replies with `CAPABILITY_PROFILE_V1`.
3) STRAT routes future work based on:
   - `hard_caps.granted`
   - permission_state
   - recent proof
   - soft priors as tie-breakers

---

## 7) Orbit + TRAM embedding (implementation roadmap)

### Orbit (docs)
- This spec is the canonical vocabulary + rules.
- Onboarding should reference this doc.

### TRAM (data + tools)
Target end-state:
- Store the latest `CAPABILITY_PROFILE_V1` per `origin_session` in DB (e.g., extend `tram_agents` or add `tram_agent_profiles`).
- `session_register` should accept `capabilities_version` and optional `profile_yaml`/`profile_json`.
- MCP server should upsert presence on every tool call using origin metadata (with DB-side throttle).

---

## 8) MCP Authentication Methods (per connector type)

The Camber MCP server (`camber-mcp`) requires authentication on all state-mutating and data routes (`/mcp`, `/sse`, `/status`). The server accepts tokens from three sources, checked in priority order:

| Priority | Method | Header / Param | When to use |
|----------|--------|----------------|-------------|
| 1 | `Authorization: Bearer <token>` | HTTP header | Default for CLI, Codex, and programmatic clients |
| 2 | `X-Camber-Token: <token>` | HTTP header | Clients that support custom headers but not `Authorization` |
| 3 | `token=<token>` | URL query param | **Claude desktop "Custom connector" and any client that cannot set HTTP headers** |

### Claude Desktop Connector (query param required)

Claude desktop's "Custom connector" UI **does not support custom HTTP headers** — it only exposes OAuth fields. When `CAMBER_MCP_TOKEN` is enforced, the connector cannot authenticate via `Authorization: Bearer`.

**Solution:** Append `?token=<CAMBER_MCP_TOKEN>` to the connector URL:
- MCP endpoint: `https://<host>/mcp?token=<token>`
- SSE endpoint: `https://<host>/sse?token=<token>`

### Security considerations for query param tokens

- Query tokens **may appear in Cloud Run access logs** and browser history.
- **Mitigations:**
  - Use a **dedicated connector token** (separate from the primary `CAMBER_MCP_TOKEN`) with shorter rotation cadence.
  - The MCP server **never logs token values** — `safeQuery()` redacts `token` from all structured logs.
  - Rotate connector tokens frequently (recommended: weekly or after any suspected exposure).
- `CAMBER_MCP_TOKEN` supports **comma-separated values** for zero-downtime rotation (e.g., `old_token,new_token`).

### OAuth 2.1 (browser clients)

Browser-based MCP clients can use the full OAuth 2.1 flow via:
- `/.well-known/oauth-protected-resource`
- `/.well-known/oauth-authorization-server`
- `/oauth/register`, `/oauth/authorize`, `/oauth/token`

OAuth tokens are validated alongside `TOKEN_SET` tokens in the `requireAuth` middleware.

---

*Last updated: 2026-02-25*
