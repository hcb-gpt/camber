# Gemini 3.1 Pro — Peer Review Registry

**Last updated:** 2026-03-01
**Reviewer:** Gemini 3.1 Pro (Google AI Studio, browser-only, no TRAM)
**Policy:** Per CEO directive, any spec with schema changes, pipeline mutations, or scoring logic must be reviewed by Gemini before DEV dispatch. STRAT sessions must append a PEER_REVIEW_GATE block.

---

## Source Locations

| Source | Platform | URL / Path |
|--------|----------|------------|
| AI Studio conversation (6 spec reviews) | Google AI Studio | [AI Studio link](https://aistudio.google.com/app/prompts?state=%7B%22ids%22:%5B%221Gtx3GzCA-P6xLwpiZgaO0Me4TpRpPLUf%22%5D,%22action%22:%22open%22,%22userId%22:%22112005737746867736050%22,%22resourceKeys%22:%7B%7D%7D&usp=sharing) |
| Bootstrapping Knowledge Problem brief | Google Drive | [Drive link](https://drive.google.com/file/d/1KUu57f8HntBdTuqUYywlxOXXzYx6v7Mo/view?usp=sharing) |
| Bootstrapping Knowledge — Critique & Action Plan | Google Drive | [Drive link](https://drive.google.com/file/d/1a09uptsuHMRIcrkBDJ9xH8bgzGDahaMr/view?usp=sharing) |

---

## Review #1: Closed-Loop Training Spec v1

- **Date:** 2026-03-01
- **Author:** strat-vp-2 (Chad directive)
- **Gemini verdict:** Structurally sound, 5 critical issues

### Key Corrections

1. **FATAL: Decouple headless scoring from iOS simulator.** UI automation is slow/flaky; pipeline scoring should compare `span_attributions` to `synthetic_ground_truth` directly in DB. Simulator only tests mutation paths (override swipe → DB write).
2. **Ground truth must be span-level, not interaction-level.** `synthetic_ground_truth.expected_project_ids text[]` maps to the whole call but CAMBER scores at span level. Multi-project scoring will falsely mark correct splits as errors. Fix: add `expected_spans jsonb` with utterance-to-project mappings.
3. **Stage 6b "auto-fix" is a world-model poison risk.** Synthetic LLM hallucinations could auto-write fake aliases into production context. Fix: `auto_staged boolean` + `proposed_world_model_updates` table. STRAT approves before production write.
4. **Async completion trap.** No mechanism to know when all 10 pipeline stages complete for a batch. Fix: run manifest with `expected_interaction_count` + timeout (15 min).
5. **Schema types:** `expected_project_ids text[]` should be `uuid[]`; `run_id` needs FK to a `synthetic_runs` table.

### Revised Ship Order (Gemini-approved)

1. Stage 1: Ground truth + labeled synthetics (add `is_synthetic = TRUE` to interactions)
2. Stage 2: Join verification + **DB trigger to hard-abort affinity_ledger writes if is_synthetic = TRUE**
3. Stage 5: Backend scoring edge function (headless, no simulator)
4. Stage 4: Headless agents write directly to triage_decisions/review_queue
5. Stage 6a + 6c: Error catalog + prompt suggestions (skip 6b auto-fix entirely)
6. Stage 3: Smoke test only — pass 5 synthetics to iOS sim to prove UI doesn't crash

### Additional Schema Corrections

- `loop_run_details` needs: `epistemic_entropy numeric(5,4)`, `evidence_support_gap numeric(5,4)` — required for Stage 6 tuning
- `expected_taxonomy_state text CHECK (IN ('SINGLE_PROJECT', 'NEEDS_SPLIT', 'UNKNOWN'))` added to ground truth

---

## Review #2: Triage Fix 7 — Multi-Project Spans

- **Date:** 2026-03-01
- **Gemini verdict:** Phase A approved, Phase B structurally questionable

### Key Corrections

1. **Phase B `span_project_attributions` is redundant in v4.** The v4 architecture enforces 1 span = 1 project via segment-llm. If a span truly covers two projects, the correct fix is better segmentation boundaries, not multi-project attribution per span.
2. **Phase A is safe** — card-reappears pattern writes separate `triage_decisions` rows per span, no integrity risk.
3. **The real fix is segment-llm quality** — if segment-llm produces better boundaries, Phase B becomes unnecessary.

---

## Review #3: Reminders Table + close_open_loop (Epics 3.1 & 3.4)

- **Date:** 2026-03-01
- **Gemini verdict:** Schema approved with fixes

### Key Corrections

1. **`close_open_loop` needs explicit transaction wrapping** — two UPDATE statements without BEGIN/COMMIT risk partial execution on crash. Wrap in `BEGIN ... COMMIT` or use `LANGUAGE plpgsql` with exception handling.
2. **`trigger_rule` JSONB is a time bomb** — no validation means malformed rules silently do nothing. Add a CHECK constraint or validation function, or at minimum a `trigger_rule_version text` column.
3. **`source_evidence` char offsets are brittle** — when transcripts are re-processed, offsets shift. Use `span_id` references instead of character positions.
4. **Staleness model:** Gemini suggests exponential decay — if no new evidence referencing an open loop appears within 30 days, auto-close probability increases. Formula: `P(stale) = 1 - e^(-t/τ)` where τ = 30 days.
5. **Missing: `updated_at` column** on reminders for tracking snooze/status changes.

---

## Review #4: Time Resolver — NLP Pattern Matching + Confidence Model

- **Date:** 2026-03-01 (already deployed, retroactive review)
- **Gemini verdict:** Confidence model needs calibration; known bugs confirmed

### Key Corrections

1. **"ASAP" → 2hr and "soon" → 48hr are arbitrary.** These should be configurable per-context (e.g., construction "ASAP" often means same-day, not 2 hours). Recommend: make these configurable constants, not hardcoded.
2. **Bare "Wednesday" disambiguation is unsolved.** If today is Wednesday and someone says "Wednesday," linguistic research favors "next Wednesday" (7 days), not "today." The spec's default (next occurrence) is correct for future-oriented scheduling language but should be flagged NEEDS_CLARIFICATION regardless.
3. **TENTATIVE timestamps should NOT write to `scheduler_items`.** Writing a speculative timestamp to the production table creates false precision. Write to `time_resolution_audit` only; surface as "suggested time" in UI.
4. **Tue/Wed compound expression:** Tokenize on `/` and `or` before day matching. "Tue/Wed" → two candidates → NEEDS_CLARIFICATION.
5. **Scoring for closed-loop:** Use ±2 hour window for MEDIUM confidence, exact-day match for HIGH, and "within-week" for TENTATIVE. Don't use exact-match — construction scheduling is inherently approximate.

---

## Review #5: Triage Fix 4 — Confidence Evidence Display

- **Date:** 2026-03-01
- **Gemini verdict:** Don't trust LLM self-reported reasoning

### Key Corrections

1. **Use independent entropy measure, not LLM reasoning.** LLMs are notoriously poorly calibrated at self-reporting confidence. Shannon entropy over the posterior distribution q(p) is a mathematically grounded measure of model confusion.
2. **Show evidence ALWAYS, not just below 65%.** Even high-confidence attributions benefit from a one-line evidence summary. It builds user trust when correct and catches errors when wrong.
3. **Anchoring bias is real.** Showing AI "reasoning" (natural language) creates anchoring — users read the explanation instead of the transcript. Fix: show the *matched transcript excerpt* (the evidence), not the AI's narrative about it.
4. **NEEDS_SPLIT badge:** Show a scissors icon with "Multiple projects detected" instead of a confidence percentage. Confidence is meaningless when the span should be split.
5. **If entropy is high but confidence is high → show warning.** This is the "hallucinated certainty" pattern: `evidence_support_gap > threshold` should override the confidence badge color to yellow regardless of the number.

---

## Review #6: Receipt Schema Update Spec (DEV21, 2026-01-24)

- **Date:** 2026-03-01 (retroactive review of January spec)
- **Gemini verdict:** STALE / ARCHITECTURALLY OBSOLETE

### Key Corrections

1. **Written pre-v4.** This spec stuffs massive JSONB receipt blobs onto `interactions` table. V4 solved this structurally with `conversation_spans`.
2. **`switch_evidence` is redundant.** In v4, project switches are segment boundaries between `span_index = 0` and `span_index = 1`. Drop entirely.
3. **`unscoped_segments` are just unattributed spans.** When ai-router can't find evidence, the posterior collapses below 0.92 and routes to UNKNOWN. No custom JSON needed.
4. **`interactions.context_receipt` is the wrong level.** Candidate generation happens per-span in v4, not per-interaction. Data must live in `span_attributions.anchors`.
5. **Char offsets in JSON = epistemic drift.** Re-transcription shifts offsets. Use `evidence_events` table with immutable `span_id` links.

### Correct v4 Implementation Path

Instead of the receipt schema, update `span_attributions.anchors` to enforce Grounded vs Proxy split:

```json
{
  "grounded_evidence": [
    {"cue_type": "project_alias", "cue_text": "Woodberry", "evidence_event_id": "uuid"}
  ],
  "proxy_evidence": [
    {"cue_type": "affinity", "weight": 0.85, "source": "correspondent_project_affinity"}
  ],
  "evidence_support_gap": 0.12
}
```

Gate C enforcement: if `grounded_evidence` is empty → route to REVIEW, never PROMOTE.

---

## Heavyweight Review: Bootstrapping Knowledge Problem

- **Date:** 2026-02-28
- **Input:** 14-section brief covering architecture, failure modes, CEO gates, mathematical framing
- **Output:** Full mathematical specification + critique + action plan

### Mathematical Framework (Approved with Modifications)

| Component | Formula | Safe Default |
|-----------|---------|--------------|
| Prior (Beta distribution) | α̃ = 1 + (α-1)e^(-λΔt), W(c,p) = α̃/(α̃+β̃) | α₀=1, β₀=1 (uniform) |
| Candidate generation | S_gen(p) = w_prior·W + w_lex·I_match + w_rec·e^(-γΔt) | K=5 candidates |
| Evidence scoring | E(x\|p) ∈ [0,1], blind to W(c,p) | θ_evidence = 0.85 |
| Posterior | q(p) = E^λE · W^λW / Σ | λE=2.0, λW=0.5 |
| Auto-assign gate | q(p) ≥ 0.92 | CEO binding |
| Human lock update | Δα = +1.0, Δβ = +1.0 for top-3 false competitors with q>0.30 | — |
| Model auto-assign update | Δα = κ = 0.05, Δβ = 0 | Deferred until QA pass |
| UNKNOWN/NEEDS_SPLIT | Zero updates (strict deadband) | CEO binding |
| Active decay | λ_active = 0.023 (30-day half-life) | — |
| Closed project decay | λ_closed = 0.1 (7-day half-life) | — |

### Gemini Self-Critique (Applied)

1. **Negative drift prevention:** Original suggestion penalized ALL other candidates on human correction. Too aggressive. Revised: only penalize top-N false competitors with q > 0.30.
2. **Decay mechanics:** 1% daily exponential decay too fast for construction (12-18 month projects). Revised: stage-based decay — priors static during active phase, rapid decay on project close/warranty.
3. **Affinity ledger:** `correspondent_project_affinity` must become a materialized fold over `affinity_ledger` table. Every delta is an auditable, reversible ledger entry.

### Circuit Breakers

| Monitor | Trip Condition | Action |
|---------|----------------|--------|
| FPR on auto-assigns | Rolling 48h FPR > 3% on 5% QA sample | Halt affinity_ledger writes; route all auto-assigns to review queue |
| Ledger churn | Σ\|Δα\|+Σ\|Δβ\| > 5.0 per contact per 24h | Quarantine contact; force UNKNOWN for 48h |
| Truth graph integrity | >1% of 24h SMS threads missing spans | Trigger idempotent replay_segment_call |

### 4 SQL Data Packets for Parameter Fitting

1. **Candidate recall distribution** — Logistic regression on human-locked spans to fit w_prior, w_lex, w_rec
2. **Evidence score margin matrix** — 95th percentile of runner-up scores to set θ_evidence
3. **Velocity ratio** — κ must be < E[human_locks]/E[auto_assigns]
4. **Project lifecycle autocorrelation** — λ = ln(2)/p90_gap_days

---

## Process Notes

### Why These Aren't in TRAM

Gemini 3.1 Pro operates in a browser with no TRAM access. Reviews exist as Google AI Studio conversations and Drive files. This is a known visibility gap — the PEER_REVIEW_GATE policy was established after most of these reviews occurred.

### Going Forward

All future Gemini peer reviews should:
1. Be summarized in a TRAM message (from: STRAT, kind: peer_review) after completion
2. Link to the source AI Studio conversation or Drive file
3. Be indexed in this document
4. Include a PEER_REVIEW_GATE block in the spec being reviewed

### How to Request a Gemini Review

1. Prepare the spec as a self-contained document
2. Open Gemini 3.1 Pro in Google AI Studio
3. Paste with prefix: "crit this spec:"
4. Copy response to Drive
5. Send TRAM summary to strat-lead
6. Update this index
