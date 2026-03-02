# TO: STRATA23
# FROM: DEV21_CAMBER_JOURNALS
# DATE: 2026-01-24_0100Z
# SUBJECT: continuity_contract_spec_2026-01-24 — cross-call continuity evidence + storage + reconstruction

Context:
- Delegation item A from STRATA23 (based on STRAT22 new failure classes: predicate-first, proxy recursion, cross-call continuity).

## Goal
Define what evidence qualifies Call B as a continuation of Call A, where that evidence is stored, and how it is reconstructed/queryable.

## Definitions
- **Call**: a single interaction record (interaction_id) with a recording_url and transcript.
- **Phone pair**: unordered tuple of normalized E.164 caller/callee numbers.
- **Continuation candidate**: a prior interaction with the same phone pair in a short time window.

## Continuity evidence requirements
Continuity is graded. Only **Strong** continuity may be used to widen context window/caches. Continuity must **never** write truth into ledger; it only affects *routing receipts* and *context assembly caches*.

### Strong continuity (qualifies as continuation)
All required:
1) Same phone pair (unordered match on E.164).
2) Time delta between calls <= **5 minutes** (configurable; see Questions).
3) At least one *explicit continuity marker* in Call B transcript **within first 30 seconds**:
   - phrases like: "got disconnected", "call dropped", "where were we", "as I was saying", "picked back up", "you cut out"
   - OR explicit reference to earlier call: "I just called you", "I was on with you"
4) No explicit switch marker indicating a new topic/project at Call B start (e.g., "different thing", "new issue", "another project").

### Medium continuity (weak continuation; should not auto-widen candidates)
Required:
1) Same phone pair
2) Time delta <= **10 minutes**
3) Transcript overlap heuristic indicates continuation (see below)
AND no explicit "new topic" marker.

### Weak continuity (record as candidate only)
- Same phone pair and time delta <= 30 minutes, but no transcript evidence.

## Transcript overlap heuristics (for Medium)
These are deterministic checks, not LLM:
- **Bigram overlap** between last 60 seconds of Call A and first 60 seconds of Call B >= threshold (default 0.15)
- OR repeated rare tokens (names, addresses, unique nouns) appear in both windows.

## Storage contract (receipt fields)
Store in **context_receipt** (or routing_receipt) as JSON; names below are canonical.

### `continuity_evidence` object
```json
{
  "is_continuation": true,
  "continuity_strength": "strong|medium|weak|none",
  "prior_interaction_id": "uuid",
  "prior_call_ended_at": "timestamptz",
  "call_started_at": "timestamptz",
  "delta_seconds": 123,
  "phone_pair_hash": "sha256(e164_a|e164_b)",
  "evidence": [
    {
      "type": "explicit_phrase|bigram_overlap|rare_token_overlap",
      "value": "got disconnected",
      "pointer": {
        "pointer_type": "transcript_span",
        "char_start": 123,
        "char_end": 156,
        "span_text": "sorry, got disconnected",
        "span_hash": "..."
      },
      "score": 0.92
    }
  ],
  "notes": "continuity does not promote truth; affects caches only"
}
```

### Requirements
- If `continuity_strength in ('strong','medium')`, at least one `evidence[]` item MUST contain a transcript_span pointer.
- If `continuity_strength='weak'`, evidence pointers are optional but should include time/phone match.

## Reconstruction query (schema-agnostic)
Given interaction_id B:
1) Read B’s `from_number`, `to_number`, `started_at`, and `context_receipt.continuity_evidence`.
2) If continuity_evidence.prior_interaction_id exists, join to A and compute delta for display.
3) Otherwise, find candidates A:
   - same unordered phone pair
   - ended_at between (B.started_at - interval '30 minutes') and B.started_at
   - choose nearest by ended_at
4) Evaluate transcript evidence rules to assign strength.

### SQL sketch (UNVERIFIED table/column names)
```sql
-- inputs: :interaction_id
with b as (
  select id, started_at, from_e164, to_e164, context_receipt
  from public.interactions
  where id = :interaction_id
),
pair as (
  select
    least(from_e164, to_e164) as a,
    greatest(from_e164, to_e164) as b
  from b
),
candidates as (
  select i.*
  from public.interactions i
  join pair p on least(i.from_e164, i.to_e164)=p.a and greatest(i.from_e164, i.to_e164)=p.b
  join b on i.ended_at between (b.started_at - interval '30 minutes') and b.started_at
  where i.id <> (select id from b)
  order by i.ended_at desc
  limit 5
)
select * from candidates;
```

## Implementation hooks (where computed)
- Should be computed once in **context assembly** (step 10) or earlier in parse_normalize:
  - needs phone numbers + timestamps + transcript text
  - writes only to receipt (and optionally a lightweight `interaction_links` table if desired)

## Open questions (need STRAT23/Chad ruling)
1) Canon time window(s): Strong=5m, Medium=10m, Weak=30m — accept?
2) What are canonical columns for phone numbers and timestamps in Gandalf? (from_e164/to_e164 vs caller/callee)
3) Where should this live: `context_receipt` vs `routing_receipt` vs a new `interaction_links` table?
4) Are explicit continuity markers mandatory for Strong continuity, or can time+phone alone ever be Strong?
