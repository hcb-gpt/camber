# Semantic XREF Integration Guidance (for DEV-3)

Scope: integrate semantic claim crossref into `edge.context-assembly` without reintroducing material-color alias leakage.

## Preconditions

1. Merge PR [#45](https://github.com/hcb-gpt/camber/pull/45) (vector backfill worker + xref RPC phone filter fix).
2. Apply migration `supabase/migrations/20260215154500_fix_xref_search_journal_claims_scope_phone_columns.sql`.
3. Run non-dry backfill via `journal-embed-backfill` until `embedded_active > 0`.

## Integration Pattern

1. Build a query embedding from transcript text in `context-assembly`.
2. Call `public.xref_search_journal_claims(query_embedding, scope_contact_id, scope_phone, result_limit, max_distance, query_hint_text)`.
3. Blend semantic score as a bounded additive signal, not an override.
4. Keep common-word/material alias guardrails in place before top-k truncation.
5. Always pass `query_hint_text` from the transcript/claim snippet so low-specificity material/color guard can constrain cross-project elevation deterministically.

## Safety Rules

1. Never treat color/material-only terms (for example `white`, `mystery white`, `granite`) as standalone assignment evidence.
2. Require corroboration from at least one non-material signal before assignment.
3. If semantic xref returns only low-specificity material language, demote signal weight and route to review.

## Proof Harness

Use:

1. `scripts/semantic_xref_high_signal_proof.sh`
2. `scripts/semantic_xref_high_signal_proof.sql`

Expected directional behavior:

1. Windship misspelling probe should surface Winship-related claims/projects near top.
2. Mystery-white probe should not surface White Residence purely from color/material similarity.
