TO:STRAT FROM:CHAD TURN:27 TS_UTC:2026-02-16T22:59:39Z RECEIPT:world_model_prep_unified_spec_v1 CORRELATION_ID:orb_20260216_bd92fb1e
---
TASK: Execute 3-phase world model data prep: Path A promotion, caller resolution, intelligent labeling pipeline
CONTEXT_PTRS: 
REQUESTED_ACTIONS: Execute Phase 1 (WP-A + WP-B) immediately. Phase 2 (WP-C through WP-G) after Phase 1 receipt. Phase 3 (WP-H) after labeling complete.
EXPECTED_RECEIPT: world_model_prep_phase1_complete
PRIORITY: HIGH
CORRELATION_ID: orb_20260216_bd92fb1e
ORIGIN_PLATFORM: cli
ORIGIN_CLIENT: claude
ORIGIN_SESSION: strat-4
IN_REPLY_TO: brute_force_labeling_wp_scoped
---

CHAD DIRECTIVE: World Model Data Prep — Unified Spec v1

Supersedes: brute_force_labeling_wp_scoped
Decision: Intelligent multi-pass pipeline replaces brute-force. Schema promotion Path A approved.
Model choice: Haiku for Pass 2 triage, Opus for Pass 3 deep label. No GPT-4.

---

## PHASE 1: DATA SUBSTRATE (dispatch immediately, parallel)

### WP-A: Correspondent Promotion (Path A)
Explode 8 `scope.correspondents` facts from `project_facts` into `project_contacts`.

Each fact contains a `key_roles` object mapping role→name. Algorithm:
1. For each correspondent fact, iterate `key_roles`
2. Resolve name → `contacts.id` (fuzzy match on contacts.name, contacts.company)
3. If no contact exists, CREATE in `contacts` table (name, phone/email from payload)
4. INSERT into `project_contacts` (contact_id, project_id, role=key from key_roles, trade=inferred, source='correspondent_promotion', is_active=true)
5. Also promote 22 `scope.contact` facts (architect, plan_designer, owner) same pattern

Expected output: ~86 new rows in `project_contacts`. Do NOT delete the source facts from `project_facts` — they retain provenance + bitemporal fields.

Proof: `SELECT COUNT(*) FROM project_contacts WHERE source = 'correspondent_promotion'` should return ~86.

### WP-B: Caller Phone Resolution
460 of 929 calls have NULL caller_name. Resolve via:
1. `SELECT DISTINCT caller_phone FROM interactions WHERE caller_name IS NULL AND caller_phone IS NOT NULL`
2. JOIN against `contacts` on phone (exact + normalized: strip +1, strip spaces)
3. JOIN against `project_contacts` to get project_id for each resolved contact
4. UPDATE `interactions SET caller_name = contacts.name WHERE ...`

This is a pure SQL join — no LLM cost. Every resolved name feeds Pass 0.

Proof: `SELECT COUNT(*) FROM interactions WHERE caller_name IS NOT NULL` before/after delta.

---

## PHASE 2: INTELLIGENT LABELING PIPELINE (after Phase 1 receipt)

### WP-C: Pass 0 — Deterministic Labels (cost: $0)
For each unlabeled span:
1. Phone match: caller_phone → contact_fanout → project_id (strongest signal)
2. Homeowner regex: if caller_name matches any project's homeowner contact, assign
3. Staff exclusion: if caller matches staff blocklist, label as `overhead`
4. Single-project vendor: if contact appears in exactly 1 project_contacts row, assign

Expected yield: ~30-40% of 929 calls labeled. Log each with `label_source = 'deterministic'`.

### WP-D: Pass 1 — Graph Propagation (cost: $0)
For remaining unlabeled spans:
1. Contact graph: if caller is in project_contacts for multiple projects, use temporal clustering (which project was active at call time based on phase.current facts)
2. Sub-contractor transitivity: if call mentions a sub who is in project_contacts for exactly one active project, propagate
3. Temporal window: calls within ±2 days of a labeled call from same phone → same project (high confidence)

Expected yield: ~15-20% more. Log with `label_source = 'graph_propagation'`.

### WP-E: Pass 2 — Haiku Triage (cost: ~$0.50)
For remaining unlabeled spans:
1. Assemble mini-context: caller_name, caller_phone, transcript first 500 chars, list of active projects with phase
2. Call Haiku: "Which project does this call belong to? Return project_id + confidence. If unsure, return null."
3. If confidence >= 0.85, accept label. Log with `label_source = 'haiku_triage'`
4. If confidence < 0.85, route to Pass 3

Expected yield: ~50% of remainder.

### WP-F: Pass 3 — Opus Deep Label + Fact Extraction (cost: ~$15-20)
For remaining hard cases:
1. Assemble FULL context: transcript, all project_facts for candidate projects, contact graph, recent call history from same phone
2. Call Opus: structured output with project_id + confidence + extracted_facts[]
3. FLYWHEEL: every extracted_fact → INSERT into project_facts with proper provenance (evidence_event_id, source_span_id, as_of_at = call timestamp, observed_at = NOW)
4. If confidence < 0.6, route to Pass 4

### WP-G: Pass 4 — Human Review Queue
Remaining low-confidence + conflicts → `review_queue` table with:
- span_id, candidate_projects[], model_scores[], transcript_excerpt
- Chad reviews in batches

---

## PHASE 3: GT EVAL + PROOF (after labeling complete)

### WP-H: Re-run GT Eval
With enriched data (promoted contacts, resolved callers, labeled spans, flywheel facts):
1. Re-run the 86-span GT sample against Haiku, Sonnet, Opus
2. Compare vs baseline: Haiku 8.2%, Sonnet 14%, GPT-4o 18%
3. Target: >= 50% on Haiku (10x lift from data alone)
4. Package proof: accuracy delta, fact count delta, contact count delta

Expected receipt: world_model_prep_phase1_complete (after WP-A + WP-B)
Final receipt: world_model_prep_all_complete (after WP-H)

---

## EXECUTION NOTES
- All SQL mutations need migration files in camber-calls/supabase/migrations/
- Labeling pipeline can be an Edge Function or a script — STRAT decides
- Use Codex Spark for discrete WPs where possible (A and B are good candidates)
- Do NOT merge M2 PRs (#122, #123) yet — gated on density proof from WP-H

