# AGENTS.md - Orbit Workspace

> This file guides AI coding agents. See [agents.md](https://agents.md/) for the standard.

> Workspace-level local-agent boot rules live at `../CLAUDE.md` and `../AGENTS.md`.
> Keep boot instructions canonical there; this file is Orbit-specific.

## Identity

You are working on **Orbit**, the orchestration workspace for Camber (Heartwood Custom Builders).

**Two repos:**
- `orbit/` (this repo) - Workspace: orchestration, TRAM messaging, governance, MCP server
- `camber/` - Product: call pipeline engine

---

## Retirement

- See `docs/contracts/retirement-triggers-v2.md` for when to self-retire.
- `retirement_confirmed` TRAM is MANDATORY — see format in `retirement-triggers-v2.md`.
- When in doubt about whether to retire: DON'T. Ask STRAT.

---

## Commands

```bash
# Boot test (run at session start)
./apps/mcp-server/scripts/tram-boot-test.sh --quick

# BOOT CHECK (required before role boot)
# 1. Run 'claude preflight'
# 2. Run 'source scripts/load-credentials.md'
# 3. Verify session_register(session_id=...) succeeds

# Full deployment verification
./scripts/verify-deployment.sh

# Validate MCP config
./scripts/mcp-validate.sh

# Load credentials (from orbit root)
source scripts/load-credentials.sh
```

---

## Project Structure

```
orbit/
├── apps/mcp-server/      # Deployable MCP server (Cloud Run)
├── config/
│   ├── agents/           # Agent role definitions
│   ├── credentials/      # Credentials (gitignored, template committed)
│   ├── deployments/      # Cloud Run manifests (source of truth)
│   ├── governance/       # RULE_DECK, protocols
│   ├── migrations/       # Database migrations
│   └── system/           # Shared env defaults, paths, boot
├── data/tram/            # TRAM messages (dual-write: Drive + GitHub)
├── docs/                 # Architecture, vision docs
├── packages/             # Shared libraries (placeholder)
└── scripts/              # Credential loader, install, preflight, verification
```

---

## Code Style

- Shell scripts: `set -euo pipefail`, use `shellcheck`
- JavaScript: Node.js, no TypeScript in MCP server
- Markdown: ATX headers, 80 char soft wrap
- YAML: 2-space indent

---

## Testing

```bash
# Canonical call for all pipeline tests
cll_06DSX0CVZHZK72VCVW54EH9G3C

# Run pipeline replay (in camber repo)
./scripts/replay_call.sh cll_06DSX0CVZHZK72VCVW54EH9G3C --reseed --reroute
```

---

## TRAM Messaging

**Primary:** Google Drive (Shared Drive)
**Backup:** GitHub (`data/tram/`)
**Dual-write:** Enabled (all writes go to both)

**Read (local agents):**
```bash
ls -t /Users/chadbarlow/gh/hcb-gpt/orbit/data/tram | head -10
```

**Write (all agents):**
Use `tram_create` via MCP - handles dual-write automatically.

**MCP URL:** `https://camber-mcp-78779153677.us-central1.run.app/mcp`

---

## Git Workflow

- Branch from `main`
- PR required for all changes
- Commit message format: `type(scope): description`
- Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

---

## Boundaries

### Always Do
- Run `./scripts/verify-deployment.sh` after any reorg
- Use canonical call ID for testing
- Write TRAM via MCP (not direct file writes)
- Run `claude preflight` before manual role starts (`you are <role>`)

### Ask First
- Deploying to Cloud Run
- Modifying `config/deployments/` manifests
- Changes to agent role definitions

### Never Do
- Commit secrets or tokens
- Direct writes to Drive TRAM folder
- Delete TRAM messages without explicit approval
- Modify RULE_DECK without governance review
- Access files outside `hcb-gpt/` without explicit Chad approval

---

## Credentials

**Sandbox rule:** Agents work inside `hcb-gpt/` — no access to broader machine.

**Source of truth:** `orbit/scripts/` and `orbit/config/credentials/`

```bash
# From orbit root (preferred for agents)
source scripts/load-credentials.sh

# Legacy (symlinked to orbit by install.sh)
source ~/.camber/load-credentials.sh
```

**Resolution order:**
1. macOS Keychain (service: `camber`)
2. `orbit/config/credentials/credentials.env` (gitignored)
3. `~/.camber/credentials.env` (legacy fallback)

**Setup:**
```bash
cp config/credentials/credentials.env.example config/credentials/credentials.env
# Fill in secrets, then:
./scripts/keychain-import.sh
```

---

## MCP Tools (21 total)

| Category | Tools |
|----------|-------|
| TRAM | `tram_list`, `tram_fetch`, `tram_create`, `tram_create_many`, `tram_ack`, `tram_unacked`, `tram_search`, `tram_mark_read`, `tram_read_status`, `tram_unread`, `tram_thread_summary`, `tram_verify`, `tram_rate_limit`, `tram_templates`, `tram_template` |
| Search | `search`, `fetch` |
| GitHub | `github_write` |
| Pipeline | `replay_call`, `shadow_single`, `shadow_batch` |

---

## Related Files

- Product context: `/Users/chadbarlow/gh/hcb-gpt/camber/OPERATING-MANUAL.md`
- Deployment manifest: `config/deployments/cloud-run-mcp.yaml`
- Agent roles: `config/agents/roles/`
- Governance: `config/governance/ORBIT-PROTOCOL.md`
