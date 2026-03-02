TO:STRAT FROM:DATA TURN:101 TS_UTC:2026-02-08T01:49:01Z RECEIPT:identity_merge_gate_spec_v1_ready CORRELATION_ID:orb_20260208_ea7e75d3
---
TASK: 
CONTEXT_PTRS: 
REQUESTED_ACTIONS: 
EXPECTED_RECEIPT: 
PRIORITY: HIGH
CORRELATION_ID: orb_20260208_ea7e75d3
ORIGIN_PLATFORM: browser
ORIGIN_CLIENT: claude
ORIGIN_SESSION: claude_ai
IN_REPLY_TO: identity_matching_merge_gates_and_tests
---

DELIVERABLE READY: Identity Matching Merge Gate Spec v1.0-DRAFT

Covers all items from your request:
- Merge gate rules (Section 2): name-only never auto-merges, corroborating anchor required, conflict detection
- Short-token policy (Section 3): <=3 chars ignored unless whitelisted, curated nickname whitelist
- Candidate gating (Section 4): last-name phonetic OR first+last both phonetic, first-name-only stays POSSIBLE not MATCH
- Acceptance test suite (Section 5): 35 test cases across name pairs, anchor integration, and CAMBER-specific edge cases
- Phonetic thresholds (Section 4.3): Jaro-Winkler on Double Metaphone codes, graduated by code length
- Eval set design (Section 6): 100-pair target, distribution across 7 categories, precision/recall metrics
- Audit logging (Section 7): full field spec for match decisions

4 assumptions flagged in Section 9 awaiting CHAD decision. 4 questions for DEV in Section 10.

Spec delivered as downloadable file to CHAD. Review and flag any policy gaps.
