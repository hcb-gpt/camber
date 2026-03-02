# TO: STRATA23
# FROM: DEV21_CAMBER_JOURNALS
# DATE: 2026-01-24_0156Z
# SUBJECT: continuity_contract_spec_v2_topic_vs_project_gates_tier_taxonomy_receipt_fields

## Source
Contract update received (Topic/Thread continuity vs Project continuity are separate gates; time-window is search limiter only; tier taxonomy required; receipt schema additions required).

## Core model (HARD)
### Gate 1 — Thread/Topic Continuity (may link, cannot promote)
Definition: “This call continues the same thread/topic about X.”
- Result: may *link* calls for context windowing and candidate widening.
- Constraint: **cannot** by itself promote a claim to a project.

### Gate 2 — Project Continuity (can promote, only with evidence)
Definition: “The claims in this call belong to Project Y.”
- Result: can support promotion **only** when backed by transcript-grounded evidence (Tier 1/2) and transcript_span pointers.

## Callback evidence taxonomy (HARD)
### Tier 1 (Strong)
Any of:
- Explicit project naming (“Woodberry”, “Hurley”, address) in current call
- Explicit callback phrasing that also names the project or explicitly links thread (“About Woodberry—same issue…”)
Requirement: must include transcript_span pointer(s) in current call.

### Tier 2 (Medium)
All of:
- Temporal callback framing (“following up”, “continuing”, “as we discussed”) in current call
- Rare referent overlap (unique noun/name/address fragment) connecting to prior call
Requirement: must include transcript_span pointer(s) in current call AND pointer(s) in prior call where the referent is grounded.

### Tier 3 (Weak)
- Shared referent only (no callback framing; no project naming).
Rule: **never** continuity evidence; may only widen candidates, and must be marked as proxy/history.

## Gap rule (HARD, thresholds TBD)
- Gap is **never** evidence.
- Longer gaps require stronger evidence:
  - For “long gaps”, Tier 1 must be mandatory.
  - Threshold values are a Chad decision (see “Open decision” below).

## Time-window rule (HARD)
- Time window is a *search limiter only* (“which prior calls to consider”), and must be logged as such.

## Receipt schema requirements (HARD)
Add to receipt JSON (context_receipt or routing_receipt as canonical store):
- continuity_candidate_calls: [call_id] searched
- continuity_evidence_spans_current: [transcript_span pointers in current call]
- continuity_link_target_call_id: prior_call_id chosen (if any)
- continuity_link_target_spans_prior: [transcript_span pointers in prior call]
- candidate_sources_split:
  - transcript_grounded: [...]
  - proxy_history: [...]

## Acceptance tests (HARD)
1) Long-gap, no project named: “Schluter backordered” + prior Woodberry call → **HOLD** (no project continuity).
2) Long-gap with callback + project named: “About Woodberry—same issue…” → may link; must log pointers chain.
3) Floater: same referent appears across multiple projects → **HOLD/REVIEW** (no proxy decision).
4) Promotion boundary: no project + no Tier 1/2 callback → **HOLD** even if prior anchor exists.

## Open decision (needs Chad/STRAT20)
Gap thresholds for Tier 1 mandatory:
- Option A: Tier2 OK < 1h; Tier1 required > 1h
- Option B (STRAT22 framing): Tier2 likely <10m; Tier1 required >30m
- Option C: Tier2 OK < 4h; Tier1 required > 4h
- Option D: Tier2 OK < 24h; Tier1 required > 24h

## UNAUTH recommendation (DEV)
Adopt Option B initially (10m/30m) to prevent proxy-recursion and continuity abuse; can be loosened once measured.
