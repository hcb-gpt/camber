# Executable spec: keep the diagram in sync with the real architecture

Audience: Claude Code (implementation agent) + maintainers.

## Goal
The Flow/System diagram must reflect the **real architecture** (source of truth) and never drift.

Problem observed: several modules that have upstream pipeline dependencies show **no blue flow lines** in Flow view.

Success means:
- Every required pipeline dependency renders as a visible **flow line** (blue) in Flow view.
- Modules that are **not pipeline-triggered** remain disconnected (e.g., `review-resolve`, `morning-digest`).
- A CI/audit check fails the build if the diagram is missing required flow connections.

## Source of truth
The diagram must be generated from a single authoritative architecture definition.

Use this precedence:

1) **Canonical flow spec** (curated, human-approved): `config/architecture_flow.json` (to be added).
2) **Live product runtime lineage** (evidence-backed): edges from `public.system_lineage_edges` (if present) with `edge_type in ('calls','triggers','touches','reads','writes')`.
   - Runtime lineage is for validation and augmentation; never infer edges that are not present in (1) unless explicitly approved.

Rationale: today runtime lineage may not capture all service→service hops. The curated architecture spec is the contract.

## Required flow connections (MUST render as blue flow lines)
These are the minimum required edges.

### Attribution + Review block
- `context-assembly` → `ai-router` (blocking call with `context_package`)
- `ai-router` → `review-triage` (queue if flagged for review)
- `ai-router` → `journal-extract` (belt & suspenders routing)

`review-resolve` must remain disconnected (human initiated).

### Perception + Journal Hooks block
- `segment-call` → `generate-summary` (after all spans processed)
- `segment-call` → `striking-detect` (per span; fire & forget)
- `segment-call` → `journal-extract` (if assigned; fire & forget)
- `ai-router` → `journal-extract` (belt & suspenders)
- `journal-extract` → `journal-consolidate` (if claims > 0)
- `chain-detect` → `Pipeline Auxiliary (call_chains)` (write)
- `loop-closure` → `Journal Tables (close loops)` (write)

### Admin / Utility
- `morning-digest` must remain disconnected (cron triggered).

## Implementation plan (files + concrete steps)

### Step 1 — Add canonical architecture file
Create: `config/architecture_flow.json`

Schema (example):
```json
{
  "version": 1,
  "updated_at": "YYYY-MM-DD",
  "nodes": {
    "context-assembly": {"title": "Context Build"},
    "ai-router": {"title": "Project Attributed"}
  },
  "aliases": {
    "journal-ext": "journal-extract",
    "journal-cons": "journal-consolidate",
    "gen-summary": "generate-summary"
  },
  "required_flow_edges": [
    {
      "from": "context-assembly",
      "to": "ai-router",
      "label": "context_package",
      "semantics": "blocking",
      "render": "flow"
    }
  ],
  "exceptions": {
    "must_be_disconnected": ["review-resolve", "morning-digest"]
  }
}
```

Rules:
- `render: "flow"` means it MUST show a blue line in Flow view.
- Store edge semantics (`blocking`, `queue`, `fire_forget`, `write`) but **render them all as flow** in Flow view.
- Maintain an `aliases` map so internal short IDs (if any) resolve to canonical IDs.

Populate `required_flow_edges` with the required connections list above.

### Step 2 — Normalize IDs (stop mismatch bugs)
Today the UI uses shortened internal IDs (e.g., `journal-ext`, `gen-summary`). This is the most common cause of "edge exists but doesn’t render".

Implement a single helper in `index.html`:
- `canon(id)` → maps any id through `aliases` to canonical.

Then, when building connections and node lookups, always use canonical IDs:
- every `connection.from` and `connection.to` must be canonicalized
- every node must have `id = canonical_id`

Preferred (best) approach:
- Rename node IDs in the node list to **real slugs** (`journal-extract`, `generate-summary`, etc.)
- Keep `aliases` only for backward compatibility.

### Step 3 — Generate Flow connections from the canonical file
Refactor `index.html` so Flow view’s blue lines come from the canonical architecture spec, not hardcoded ad-hoc connection objects.

Concretely:
- Load `config/architecture_flow.json` (inline import or fetch; keep local file).
- Build `flowConnections = required_flow_edges.map(e => ({from: canon(e.from), to: canon(e.to), type: 'data-flow', label: e.label}))`.
- Merge these into the existing `connections` array (or keep two arrays and render conditionally).

Hard rule:
- In Flow view, every edge in `required_flow_edges` renders as `type: 'data-flow'`.

### Step 4 — Ensure System/Details views do NOT hide Flow edges
If System/Details apply filters by connection type or preset, ensure:
- Flow edges are always present in Flow preset
- and not accidentally filtered out due to type mismatch (e.g., `event`, `fire-forget`)

### Step 5 — Add an automated audit that fails if the diagram drifts
Create: `scripts/audit_flow_edges.mjs`

Behavior:
1) Parse `config/architecture_flow.json`.
2) Parse `public/diagram.nodes.json` and `public/diagram.connections.json` for node and connection IDs.
3) Canonicalize IDs using `aliases`.
4) Assert:
   - Every `required_flow_edge` has a matching connection with the same canonical `from` and `to`.
   - Every `exceptions.must_be_disconnected` node has **no inbound** data-flow edge in Flow view.

Output:
- Print a clear diff:
  - missing edges
  - unexpected inbound edges to disconnected nodes
- Exit non-zero on failure.

Add npm script:
- `npm run audit:flow`

### Step 6 — (Optional but recommended) Validate against live product runtime lineage
Create: `scripts/validate_against_runtime_lineage.mjs`

Inputs:
- A public artifact endpoint base URL (no secrets), e.g.
  `https://<project>.supabase.co/functions/v1/camber-map-artifact`

Behavior:
- Fetch `map.json` from the live artifact endpoint.
- Extract runtime edges where `from` and `to` are both `edge:*`.
- Compare to `required_flow_edges`:
  - If runtime shows an edge not in spec → report as "candidate architecture update".
  - If spec requires an edge never seen in runtime for N days → warn (instrumentation might be missing or edge is dead).

This script should NOT fail CI by default; it’s a visibility tool.

## Acceptance criteria

Visual:
- In Flow view, all required connections above show visible blue flow lines.
- `review-resolve` and `morning-digest` remain disconnected.

Automated:
- `npm run audit:flow` passes.
- If an edge is removed/renamed in code, the audit fails with a clear message.

Regression tests (manual quick check):
- Load Flow view and confirm blue lines exist for:
  - context-assembly → ai-router
  - ai-router → review-triage
  - ai-router → journal-extract
  - segment-call → generate-summary
  - segment-call → striking-detect
  - segment-call → journal-extract
  - journal-extract → journal-consolidate
  - chain-detect → call_chains
  - loop-closure → journal tables

## Implementation notes / pitfalls
- Most missing lines are due to **ID mismatch** (aliases) or edges typed as something other than `data-flow`.
- Avoid letting Flow view rely on UI presets that may filter out edges.
- Keep the canonical spec in a single file so product/architecture changes are deliberate and reviewable.

## Deliverables checklist (Claude Code)
- [ ] Add `config/architecture_flow.json` with required edges + aliases + exceptions
- [ ] Refactor `index.html` to generate Flow edges from that file
- [ ] Canonicalize node IDs (prefer real slugs)
- [ ] Add `scripts/audit_flow_edges.mjs` + `npm run audit:flow`
- [ ] Update README with "architecture is source of truth" and how to edit the spec
