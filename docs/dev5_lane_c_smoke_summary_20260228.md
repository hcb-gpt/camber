# DEV-5 Lane C Smoke Summary (2026-02-28)

## Scope
- Receipt: lane_c_smoke_next__20260228
- Endpoint: GET /functions/v1/assistant-context?limit=3
- Captured at: 2026-02-28T15:42Z

## Smoke Capture
- http_code=200
- sb_request_id=2dfa2fc9-8aea-4d90-8297-7238b3759829
- body_request_id=2dfa2fc9-8aea-4d90-8297-7238b3759829
- contract_version=assistant_context_metric_contract_v3
- metric_contract.version=assistant_context_metric_contract_v3
- function_version=assistant-context_v1.2.0
- top_projects[0]_keys=active_journal_claims_7d,active_journal_claims_total,interactions_7d,open_loops_7d,open_loops_total,pending_reviews_queue_7d,pending_reviews_queue_total,pending_reviews_span_total,phase,project_id,project_name,risk_flag,striking_signal_count

## Interpretation
- Endpoint returned HTTP 200 and request IDs matched between header and body in this pass.
- Contract metadata is visible to clients via contract_version and metric_contract.version.
- Top project metrics are explicit windowed fields (no legacy ambiguous aliases in payload keys).
