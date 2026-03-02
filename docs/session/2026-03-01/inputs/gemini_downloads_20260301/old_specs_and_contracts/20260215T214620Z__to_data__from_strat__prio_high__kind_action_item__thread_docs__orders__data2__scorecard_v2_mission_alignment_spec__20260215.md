TO:DATA FROM:STRAT TURN:2886 TS_UTC:2026-02-15T21:46:21Z RECEIPT:orders__data2__scorecard_v2_mission_alignment_spec__20260215 CORRELATION_ID:orb_20260215_34810d9e
---
TASK: Draft Scorecard v2 spec: align MVP scorecard to Camber mission/vision + five truth lanes + user outcomes.
CONTEXT_PTRS: /Users/chadbarlow/Desktop/camber_final_product.html
/Users/chadbarlow/Desktop/camber_journal_gap_analysis.html
/Users/chadbarlow/Desktop/camber_mvp_scorecard.html
REQUESTED_ACTIONS: FOR_SESSION=data-2
Read mission/vision in `camber_final_product.html` + epistemology promises in `camber_journal_gap_analysis.html` and propose a Scorecard v2 structure that keeps the big picture visible.
Deliver:
1) A 1–2 page spec with sections:
- North Star (user outcomes): “prevent ambush / next best action” leading indicators + how to measure
- Trust lanes: Evidence / Claim / Ledger / Snapshot / Outcome (from gap analysis)
- Attribution gating: homeowner override, staff-name leak rate, contact anchoring recall, review contamination
- Time-synced crossref: as-of compliance tests + provenance coverage
2) For each metric: definition, source tables/queries, as_of_utc semantics, target threshold.
3) A minimal patch suggestion (bullets) for `camber_mvp_scorecard.html` (no direct edit required).
No DB mutations.
EXPECTED_RECEIPT: completion__data2__scorecard_v2_mission_alignment_spec__20260215
PRIORITY: HIGH
CORRELATION_ID: orb_20260215_34810d9e
---

Goal: keep mission/vision on-screen in the scorecard. Make it obvious how today’s work (attribution, evidence pointers, as-of world model, deterministic gates) ladders to the user promise in the Final Product Vision.
