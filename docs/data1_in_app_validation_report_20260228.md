# DATA-1 In-App/Harness Validation Report (2026-02-28)

## Scope
- Directive receipt: `directive__data_changes_require_app_validation_via_assistant_and_triage__20260228`
- Goal: verify DATA-lane changes through live app-facing endpoints and compare with DB proof.

## Validation 1: Assistant Context Endpoint
- Endpoint: `GET /functions/v1/assistant-context?limit=25`
- Request ID: `sb-request-id=019ca298-6741-7dd3-b207-3d160e6cbfa7`
- Trace ID: `x-deno-execution-id=8fc58f47-2c35-40c3-9944-d9f2009da808`

Observed payload:
- `function_version=assistant-context_v1.0.0`
- `metric_contract=null`
- `top_projects[*].active_journal_claims_total/_7d` missing (`null`)
- `top_projects[*].pending_reviews_queue_total/_7d` missing (`null`)

DB proof (same projects):
- Source query: `scripts/sql/assistant_context_packet_numbers_proof_20260228.sql`
- `Woodbery Residence`
  - expected contract values: `claims_total=1581, claims_7d=620, loops_total=128, loops_7d=126, queue_pending_7d=29`
  - live assistant payload currently shows legacy display values: `claims=1581, loops=128, pending_reviews=70`
- `Moss Residence`
  - expected contract values: `claims_total=157, claims_7d=102, loops_total=17, loops_7d=16, queue_pending_7d=26`
  - live assistant payload currently shows legacy display values: `claims=157, loops=17, pending_reviews=92`

Result:
- `BLOCKED` for assistant validation of new contract in production runtime.
- Root finding: deployed runtime is still pre-change (`v1.0.0`) despite merged code/migrations.

## Validation 2: Triage Queue Endpoint
- Endpoint: `GET /functions/v1/redline-thread?action=triage_queue&limit=500`
- Request ID: `sb-request-id=019ca298-9790-7ae7-9f75-6d1a66dbc0c7`
- Trace ID: `x-deno-execution-id=f354383f-b63d-41e6-81e5-d55bda1f8a65`

Observed payload:
- `function_version=redline-thread_v3.3.0`
- `count=300` (UI page cap)
- `total_pending=426` (true backlog)

DB parity check:
- Query: `select to_jsonb(v_review_queue_summary) from public.v_review_queue_summary;`
- DB value: `pending_total=426`
- Endpoint parity: `total_pending=426` (match)

Result:
- `PASS` for triage backlog parity when using `total_pending`.
- Note: UI should not read `count` as backlog because it is capped by `limit` (max 300).

## Summary
- Assistant lane: blocked by rollout mismatch (runtime still old version).
- Triage lane: validated and consistent with DB backlog totals.
