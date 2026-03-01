# World Model Architecture v0 (project_facts + evidence_events)

**Status:** DRAFT — aligned to STRAT-2 non‑negotiables v0 (2026-02-16); gaps G1–G3 tracked below  
**Owner:** DATA-3  
**Date:** 2026-02-16  
**Scope:** Design only (no migrations applied in this doc)

This spec defines the minimum viable “world model” substrate in `camber` using the existing tables:
- `public.evidence_events` (immutable-ish evidence ledger)
- `public.project_facts` (time-aware, provenance-backed facts keyed by `project_id`)

It also proposes a **delta plan** for how to extend retrieval + indexing without redesigning the schema prematurely.

---

## 0) Goals / Non-goals

### Goals
1. **Time-aware retrieval**: support “what was true as-of `t_call`?” and “what did we know as-of `t_call`?”.
2. **Pointer-backed provenance**: every promoted fact can be traced to evidence (`evidence_event_id` and/or `interaction_id`, ideally down to span + char offsets).
3. **Minimal fact taxonomy**: a small set of `fact_kind` values that cover attribution + scheduling context needs.
4. **Fast SQL primitives**: predictable <100ms queries for “top facts for these 1–5 candidate projects”.

### Non-goals (v0)
- Not a full belief revision engine (supersession/conflict graphs belong in journal/belief lanes).
- Not implementing typed columns (value_text/value_num/etc.) unless retrieval demands it.
- Not replacing existing “journal_claims” context surfaces yet; this is additive.

---

## 1) Existing Tables (authoritative as shipped)

### 1.1 `public.evidence_events` (G9 evidence layer)

Core idea: **one stable ID per evidence artifact**, with write-once immutability on payload reference and hash.

Key columns (per migrations):
- `evidence_event_id` (UUID, PK)
- `source_type` ∈ {`call`,`sms`,`photo`,`email`,`buildertrend`,`manual`}
- `source_id` (original id, e.g. `interaction_id`)
- `payload_ref` (WRITE-ONCE), `integrity_hash` (WRITE-ONCE)
- `transcript_variant` ∈ {`keywords_off`,`keywords_on`,`baseline`,NULL}
- `occurred_at_utc` (when event happened), `ingested_at` (capture time), `created_at`, `updated_at`
- “law stamps”: `canon_pack_version`, `promotion_policy_version`, `norm_version`, `segmentation_version`
- `participants_json` (structured participants), `source_run_id`, `metadata`

**Invariants (current):**
- `payload_ref` and `integrity_hash` are write-once (trigger-enforced).
- Unique `(source_type, source_id, transcript_variant)` prevents duplicate evidence rows per source+variant.

### 1.2 `public.project_facts` (time-sync facts layer)

Core idea: **bitemporal facts** with best-effort provenance pointers.

Key columns (per migrations):
- `project_id` (FK)
- `as_of_at` (effective time), `observed_at` (recorded/system time)
- `fact_kind` (text), `fact_payload` (jsonb)
- provenance pointers (nullable, best-effort):
  - `interaction_id` (text, FK to `interactions.interaction_id`)
  - `evidence_event_id` (uuid, FK to `evidence_events.evidence_event_id`)
  - `source_span_id` (uuid, FK to `conversation_spans.id`)
  - `source_char_start`, `source_char_end` (0-based, end-exclusive)

**Invariant (current):**
- char offsets are all-or-nothing and must have bounds (`source_char_start >= 0`, `source_char_end > source_char_start`).

---

## 2) Time Semantics (v0)

We model two time axes:

1) **Effective time** (`as_of_at`) — when the fact is/was true.  
2) **System/knowledge time** (`observed_at`) — when the system recorded the fact.

### 2.1 Recommended conventions

**For facts extracted from a call span:**
- `as_of_at := evidence_events.occurred_at_utc` (or `interactions.event_at_utc`)
- `observed_at := now()` (when written)
- Set provenance:
  - `interaction_id := <call interaction_id>`
  - `evidence_event_id := <call evidence_event_id>` (preferred durable join)
  - `source_span_id + source_char_*` when pointer-quality allows

**For facts sourced from Buildertrend / email / docs:**
- `as_of_at := occurred_at_utc` of that evidence event (if known) else best estimate
- `observed_at := now()`
- `evidence_event_id := <that evidence>`

**For manual curation / GT labeling:**
- Use `source_type='manual'` evidence_events rows for provenance.
- Add `fact_payload.tags := ['PLANS_GT']` when a fact represents “ground truth / operator plan” rather than “observed reality”.

### 2.2 Retrieval modes (important)

We should support two query modes — but **KNOWN_AS_OF is the default** when building context packs.

**Mode A: TRUTH_AS_OF(t)**  
Use when building the best world model today about the past (GT evaluation + manual analysis only).
- Filter: `as_of_at <= t`
- Ignore: `observed_at`

**Mode B: KNOWN_AS_OF(t)** (anti “now leakage”)  
Use when evaluating historical performance or generating context that must not use future knowledge.
- Filter: `as_of_at <= t AND observed_at <= t`

**Mandatory operational constraints (STRAT-2 N2):**
- **Default:** `context-assembly` MUST use **KNOWN_AS_OF** when building context packs.
- **Same-call exclusion:** exclude any facts whose `evidence_event_id` or `interaction_id` matches the current call (mandatory, not optional).
- Mode A (TRUTH_AS_OF) is only allowed for GT evaluation and manual analysis.

---

## 3) Provenance Policy (v0)

### 3.1 Pointer requirements by fact class

We explicitly tier fact types by required evidence. **These are enforcement requirements (STRAT-2 N3), not conventions.**

1) **Execution-critical** (permits approved, payment received, schedule commitment, inspection passed)
   - Must include `evidence_event_id`
   - Should include `source_span_id + char offsets` when derived from transcript text

2) **Planning-level / soft** (preferences, “might”, rough ideas)
   - Must include `evidence_event_id` OR `interaction_id`
   - Span pointers best-effort

3) **Static / registry facts** (address, city, permit jurisdiction)
   - Prefer to **live on `projects`** (not duplicated), or be expressed as a fact with provenance `source_type='manual'` if we need time variance.

### 3.2 Char offset semantics (align with pointer functions)

- Offsets are **0-based**.
- `source_char_end` is **exclusive**.
- Offsets are interpreted against the text of the referenced `source_span_id`’s transcript field (span-level transcript string at write time).

### 3.3 Durable join key

`evidence_event_id` is the durable join key across modalities. Prefer it over `source_id` wherever possible.

---

## 4) Minimal Fact Taxonomy (v0)

Guidelines:
- Keep `fact_kind` **stable** and human-readable.
- Keep `fact_payload` **small** and typed (strings/numbers/booleans/ISO timestamps).
- Include optional fields:
  - `confidence` (0–1)
  - `tags` (array of strings, e.g. `PLANS_GT`)
  - `source_ref` (object with extra provenance metadata when needed)

### 4.1 Proposed initial `fact_kind` set

1) `contact.assignment`
- payload: `{ contact_id, contact_name, role, strength, notes? }`
- purpose: attribution prior + “who is involved on this project”

2) `permit.status`
- payload: `{ status, jurisdiction?, details?, expected_by? }`

3) `schedule.milestone`
- payload: `{ milestone, date?, window_start?, window_end?, status? }`

4) `scope.feature`
- payload: `{ feature, value?, unit?, status?, notes? }`  
  (e.g., “motorized screens”, “Japanese siding”, “thermal wood”)

5) `vendor.involvement`
- payload: `{ contact_id, contact_name, trade?, company?, phone?, strength? }`

6) `risk.issue`
- payload: `{ issue, severity, blocking?, owner_contact_id? }`

### 4.2 Supersession / corrections (v0 policy)

Until we add explicit `supersedes_fact_id`, use a **soft supersession** convention:
- Newer fact wins for the same `(project_id, fact_kind, fact_payload.fact_key)` if present.
- Encode a stable `fact_key` inside `fact_payload` for facts that update (e.g., `fact_key='permit_status'`).

**Hard gate before production reads (STRAT-2 N4):**
- Soft supersession is acceptable for v0 seeding, but **before `context-assembly` reads `project_facts` in production**, we must define an explicit supersession policy (e.g., `supersedes_fact_id` or an equivalent conflict-resolution mechanism).

---

## 5) Retrieval Integration Sketch (v0)

### 5.1 Primitive: “facts for candidate projects”

Input:
- `project_ids[]`
- `t_call` (timestamp)
- `mode` ∈ {`KNOWN_AS_OF`, `TRUTH_AS_OF`}
- `lookback` (default 90d)

Output:
- up to N facts per project, capped by kind:
  - `permit.status` (≤2)
  - `schedule.milestone` (≤5)
  - `contact.assignment` / `vendor.involvement` (≤10)
  - `risk.issue` (≤5)
  - `scope.feature` (≤5)

Suggested SQL shape (not executed here):
- Filter by `project_id IN (...)`
- Filter by time mode (Section 2.2)
- Optional lookback: `as_of_at >= (t_call - interval '90 days')` for high-churn kinds
- Order: `as_of_at DESC, observed_at DESC`

**Retrieval stance (STRAT-2 D3):**
- Retrieval is **key-based selection** for 1–5 candidate projects (project_id + fact_kind + recency).
- Defer FTS/trgm over `fact_payload` until proven need.

### 5.2 Where to plug in

Near-term:
- `context-assembly` can fetch **project_facts** alongside (or replacing) `journal_claims` snippets for candidate projects.
- Use the same *contact-scope guard* concept: if `contact_id` is NULL, either skip facts or only include “global” kinds to reduce cross-contact leakage.

Mid-term:
- After consolidation, promote consolidated “current state” into `project_facts` as the read-optimized world model surface.

---

## 6) “Project Documents” (minimal design options)

We need a way to associate documents/photos/emails with a project, while keeping evidence immutable.

### Option A (recommended for v0): reuse `evidence_events` + add linking facts
- Use `evidence_events` as the document registry (`source_type` in {`photo`,`email`,`manual`,...}).
- Link to a project by writing a `project_facts` row with:
  - `fact_kind='document.ref'`
  - payload: `{ doc_kind, title?, summary?, tags? }`
  - set `evidence_event_id` to the doc evidence row

Pros: no new tables; consistent provenance; time-aware by default.  
Cons: discovery queries may require JSON filters / indexing.

### Option B: add `project_documents` join table (still uses evidence_events)
- Columns: `project_id`, `evidence_event_id`, `doc_kind`, `title`, `created_at`
- Evidence payload still lives in `evidence_events.payload_ref`.

Pros: simpler listing; easier indexing.  
Cons: new table + migrations.

---

## 7) Indexing / Storage Strategy (delta plan)

The open design choice: **JSON-only vs typed columns**.

### 7.1 Recommendation: stay JSON-first, add generated columns + indexes

If retrieval needs “fact_key” lookups, add *generated columns* over json:
- `fact_key := (fact_payload->>'fact_key')`
- `value_text := (fact_payload->>'value')` when patterns converge

Index plan (suggested):
- `GIN` on `fact_payload` for key existence filters
- `(project_id, fact_kind, as_of_at desc)` already exists; consider `(project_id, fact_kind, fact_key, as_of_at desc)`

### 7.2 When to graduate to typed storage

Add typed columns or a new table only when:
- We have ≥3 high-volume kinds needing range queries (`date between`, numeric comparisons), OR
- We need FTS/trgm over fact values as a primary retrieval path.

---

## 8) Example Facts (Woodbery-style rows)

Using canonical Woodbery project id: `7db5e186-7dda-4c2c-b85e-7235b67e06d8`.

> Note: these are illustrative row shapes; evidence pointers are best-effort and may be partial depending on source.

### Example 1 — vendor involvement (masonry)
- `project_id`: `7db5e186-7dda-4c2c-b85e-7235b67e06d8`
- `as_of_at`: `2026-01-28T16:13:23Z`
- `observed_at`: `<write_time_utc>`
- `fact_kind`: `vendor.involvement`
- `fact_payload`:
  ```json
  {
    "contact_id": "07389e46-eaa4-4f1f-b636-44d8082268bc",
    "contact_name": "Luis Juarez",
    "trade": "Masonry",
    "strength": "strong",
    "tags": ["anchor_catalog_v1"]
  }
  ```
- `interaction_id`: `cll_06E0ARC879S855FPXM71S6EBJR`

### Example 2 — vendor involvement (development / professional)
- `project_id`: `7db5e186-7dda-4c2c-b85e-7235b67e06d8`
- `as_of_at`: `2026-01-31T19:08:41Z`
- `observed_at`: `<write_time_utc>`
- `fact_kind`: `vendor.involvement`
- `fact_payload`:
  ```json
  {
    "contact_id": "a3b4c5d6-e7f8-9012-abcd-ef1234567890",
    "contact_name": "Brad Stephens",
    "trade": "Development",
    "strength": "moderate",
    "tags": ["anchor_catalog_v1"]
  }
  ```
- `interaction_id`: `cll_06E1AX8T2NZJQ560Q2FJ7BZAKM`

### Example 3 — permit jurisdiction as a time-aware fact (if it ever changes)
- `project_id`: `7db5e186-7dda-4c2c-b85e-7235b67e06d8`
- `as_of_at`: `<project_created_or_first_known>`
- `observed_at`: `<write_time_utc>`
- `fact_kind`: `permit.jurisdiction`
- `fact_payload`:
  ```json
  {
    "jurisdiction": "Morgan County",
    "fact_key": "permit_jurisdiction",
    "confidence": 0.9,
    "tags": ["project_registry"]
  }
  ```
- provenance: `evidence_event_id` should point to the registry source (or `manual` evidence event)

---

## 9) Acceptance Proofs (for later execution)

These are proof queries to validate the design once we start writing facts:

1) **Provenance hygiene**
- No “half pointers” (char_start XOR char_end)
- If char offsets exist, `source_span_id` exists

2) **Leakage checks**
- For a given `interaction_id`, count facts included under `KNOWN_AS_OF(t_call)` vs excluded by `observed_at > t_call`.
- Ensure context injection never includes facts from the same call’s `evidence_event_id`.

3) **Latency**
- “facts for candidate projects” query p95 under 100ms with N<=5 projects.

---

## 10) Pending STRAT-2 non‑negotiables (explicit placeholder)

This spec is aligned to STRAT-2 “world model” non‑negotiables v0 (2026-02-16).

### Decisions (D1–D3)
- **D1 JSON-first:** no typed columns yet; prefer generated columns + GIN only when needed.
- **D2 No new tables:** use `evidence_events` + linking facts (`fact_kind='document.ref'`), no `project_documents` table in v0.
- **D3 Key-based retrieval:** for 1–5 candidate projects by kind/recency; defer FTS/trgm until proven need.

### Hard constraints (N1–N4)
- **N1 Stopline alignment is mandatory:** facts must not create any path to write `interactions.project_id`; must not bypass attribution_lock monotonicity; fact-write failures must fail-closed (no silent 200).
- **N2 Anti-leakage default:** KNOWN_AS_OF must be default in context pack assembly; same-call exclusion is mandatory.
- **N3 Provenance tier enforcement:** execution-critical facts require `evidence_event_id`; planning-level facts require `evidence_event_id` OR `interaction_id`; reject orphan facts.
- **N4 Supersession clarity before prod reads:** soft supersession OK for seeding; explicit supersession required before production context packs read `project_facts`.

## 11) Gaps (G1–G3) — required doc sections

These gaps must be explicitly owned/closed before the spec is treated as “merge-ready” for implementation.

### G1 Auth model for fact writes (TBD, must be explicit)

v0 proposal (doc-only):
- **Write entrypoints:** a single RPC (e.g., `write_project_facts_v0`) invoked only by internal Edge Functions (service role).
- **Auth pattern:** internal `X-Edge-Secret` gate at the function boundary + service role DB key; no end-user JWT writes.
- **RLS stance:** keep `project_facts` service-role only in v0; formalize RLS later when there is a UI/editor.
- **Stopline enforcement location:** inside the write RPC/function (reject any attempt to touch Stopline 1/2 surfaces; fail closed on write error).

### G2 Deletion / retraction policy (TBD, append-only preferred)

v0 proposal:
- **No hard deletes** for facts once written.
- Use an append-only **retraction** pattern (a new fact that references the prior fact id) and a “current facts” read view that excludes retracted rows.
- If we need soft deletion later, add explicit lifecycle fields; do not rely on ad-hoc deletes.

### G3 GT correction interaction (span_attributions ↔ project_facts)

v0 stance:
- GT corrections (via `apply_gt_correction` / human overrides in `span_attributions`) remain the source of truth for attribution evaluation.
- `project_facts` seeding should not be automatically mutated by GT corrections until there is a defined, audited promotion policy for facts.

Future integration (post-v0):
- GT corrections can trigger re-extraction / consolidation that yields updated facts, but only through the same stopline-safe write path defined in G1.
