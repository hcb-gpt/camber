# TO: STRATA23
# FROM: DEV21_CAMBER_JOURNALS
# DATE: 2026-01-24_0100Z
# SUBJECT: receipt_schema_update_spec_2026-01-24 — transcript vs proxy candidate sources + continuity/switch evidence

Context:
- Delegation item D: enforce candidate_sources split (transcript vs proxy) + continuity/switch evidence fields.
- Aligns with STRAT22 failure classes: predicate-first, proxy recursion, cross-call continuity.

## Design principles
1) Receipts must separate **grounded** vs **proxy** cues:
   - grounded = transcript spans (project names, addresses, explicit referents)
   - proxy = affinity, recency, last-project, contact-project graph
2) Proxy cues may widen candidates but must not decide truth by themselves.
3) Any PROMOTE lane claim must have transcript_span pointer(s) satisfying Gate B.

## Proposed JSON schema additions (context_receipt)
These are JSON fields; if stored in a JSONB column, no DB migration is required to begin writing them.
A follow-on can add a view/materialization for queryability.

### 1) Candidate sources split
```json
{
  "candidate_sources_transcript": [
    {
      "project_id": "uuid",
      "cue_type": "project_name|address|client_name|local_moniker|role_name",
      "cue_text": "Hurley / 123 Bethany Rd",
      "pointer": {
        "pointer_type": "transcript_span",
        "char_start": 1000,
        "char_end": 1040,
        "span_text": "that Hurley lady...",
        "span_hash": "..."
      },
      "score": 0.82
    }
  ],
  "candidate_sources_proxy": [
    {
      "project_id": "uuid",
      "cue_type": "affinity|recency|last_project|contact_active_project",
      "cue_text": "affinity_edge_strength=0.71",
      "score": 0.71,
      "meta": { "edge_id": "uuid" }
    }
  ]
}
```

### 2) Predicate-first / unscoped labeling
```json
{
  "unscoped_segments": [
    {
      "reason": "predicate_first_missing_noun",
      "pointer": {
        "pointer_type": "transcript_span",
        "char_start": 0,
        "char_end": 420,
        "span_text": "we need to get it moved over...",
        "span_hash": "..."
      }
    }
  ]
}
```
Contract:
- Any claims extracted whose pointers fall entirely within an unscoped segment must route to HOLD/REVIEW unless later re-anchored.

### 3) Continuity evidence
Include a top-level `continuity_evidence` object (see continuity contract spec).

### 4) Switch evidence (mid-call project switches)
```json
{
  "switch_evidence": [
    {
      "from_project_id": "uuid",
      "to_project_id": "uuid",
      "pointer": {
        "pointer_type": "transcript_span",
        "char_start": 2200,
        "char_end": 2265,
        "span_text": "over at Woodberry...",
        "span_hash": "..."
      },
      "switch_type": "explicit_marker|implicit_shift|topic_reset",
      "confidence": 0.74
    }
  ]
}
```

## Migration / queryability plan
Phase 1 (now): write JSON fields into existing receipt JSONB.
Phase 2 (Gate A proof hardening): create a view extracting these fields for SQL queries.

### View sketch (UNVERIFIED)
```sql
create or replace view public.context_receipt_v2 as
select
  i.id as interaction_id,
  jsonb_array_elements(i.context_receipt->'candidate_sources_transcript') as cs_transcript,
  jsonb_array_elements(i.context_receipt->'candidate_sources_proxy') as cs_proxy
from public.interactions i;
```

## Enforcement hooks (where used)
- Context assembly builds candidates:
  - populate both arrays
  - keep proxy-only candidates marked and avoid auto-promotion downstream
- Promotion boundary (Gate C):
  - requires transcript-based pointer(s) for PROMOTE
  - routes proxy-only claims to REVIEW/HOLD

## Open questions
1) Where is `context_receipt` stored (table/column name) and is there a separate `routing_receipt`?
2) Are receipts persisted per interaction, per claim, or both?
3) Should we require that every candidate_sources_transcript item includes a transcript_span pointer (recommended: yes)?
