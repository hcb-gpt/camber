# REPO_MAP -- Two-Repo Strategy

## This Repo: `camber-calls` (PRODUCT)

SSOT for all product code that ships to users.

| Directory | Contents |
|-----------|----------|
| `supabase/functions/` | Edge Functions (call pipeline, webhooks, review-swarm) |
| `supabase/migrations/` | DB schema migrations (numbered, append-only) |
| `ios/CamberRedline/` | iOS app (SwiftUI, Redline/Triage/Assistant tabs) |
| `scripts/` | Product scripts (smoke tests, deploy helpers) |
| `tests/` | Product test suites |
| `docs/` | Product documentation (pipeline, auth contracts, etc.) |
| `static/` | Static assets |
| `artifacts/` | Build/test artifacts (gitignored scratch) |
| `.temp/` | Scratch directory (gitignored) |

## Sibling Repo: `orbit` (OPS)

SSOT for orchestration, tooling, and governance.

| Directory | Contents |
|-----------|----------|
| `docs/` | Boot docs (boot-protocol, roles, role-boundaries, charter) |
| `data/tram/` | TRAM message history |
| `config/governance/` | Charter, founding policies, governance rules |
| `config/agents/` | Agent configuration files |
| `config/deployments/` | Deployment manifests (Cloud Run, etc.) |
| `apps/mcp-server/` | MCP server (Cloud Run, TRAM tools, Orbit docs) |
| `apps/camber-map/` | Camber Map (system topology) |
| `scripts/` | Infrastructure scripts (deploy, verify, sync) |

## Archived Repos (read-only)

| Repo | Status |
|------|--------|
| `ora` | Split between product and ops; superseded |
| `camber` (legacy) | Superseded by `camber-calls` |
| `camber-calls-ship` | Drift-closed worktree; do not use |

## Where Does X Go?

| Task | Repo |
|------|------|
| New Edge Function | `camber-calls` |
| New DB migration | `camber-calls` |
| iOS change | `camber-calls` |
| Product test | `camber-calls` |
| Pipeline config | `camber-calls` |
| New boot doc | `orbit` |
| MCP server change | `orbit` |
| TRAM format change | `orbit` |
| Governance/charter update | `orbit` |
| Agent config change | `orbit` |
| Deployment manifest | `orbit` |
| Camber Map update | `orbit` |
| Infrastructure script | `orbit` |
