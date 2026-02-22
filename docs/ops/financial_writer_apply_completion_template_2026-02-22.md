# Completion Template: Financial Writer Apply Verified

Use this after the apply owner runs migration apply + proof SQL.

---
COMPLETES_RECEIPT: assist__data3_finalize_proof_packet_after_data2_apply__20260222_0728z  
RESOLUTION: DONE  
MIGRATION_PROOF: 20260222064600_patch_scheduler_financial_writer (applied; include apply log pointer/timestamp)  
DEPLOY_PROOF: NONE (DB migration only; no edge function deploy)  

VERIFY_PROOF:
- Query file: `scripts/proof_financial_writer_apply.sql`
- `rows_financial_json = <N>`
- `rows_with_committed = <N>`
- `rows_with_invoiced = <N>`
- `rows_with_pending = <N>`
- `rows_with_any_amount = <N>` (must be > 0)

REAL_DATA_POINTER:
- sample scheduler_items IDs (with canonical keys): `<id1>, <id2>, <id3>`
- sample interaction IDs: `<interaction_id1>, <interaction_id2>`
- normalized_by marker observed: `materialize_scheduler_items_v2` on sample rows

DOWNSTREAM_SMOKE:
- `select * from public.v_financial_exposure limit 3;`
- sample project rows returned: `<project_id/name pairs>`

BEFORE/AFTER:
- before `rows_with_any_amount`: `0`
- after `rows_with_any_amount`: `<N>`

GIT_PROOF:
- commit SHA containing migration patch: `99e2f8de7538f4c1517512d69149ac0e18db4c29`
- branch: `feat/agentic-assembler-sandwich-v0`

CONTEXT_AVAILABILITY:
- apply owner execution logs + linked DB query output.
---
