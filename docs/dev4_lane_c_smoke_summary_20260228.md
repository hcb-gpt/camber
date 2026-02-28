# DEV-4 Lane C Smoke Summary (2026-02-28)

## Scope
- Receipts:
  - `lane_c_smoke__capture_request_id__20260228`
  - `lane_c_smoke__log_contract_version__20260228`
- Endpoint: `GET /functions/v1/assistant-context?limit=3`
- Captured at: `2026-02-28T15:37Z`

## Smoke Capture
- `sb_request_id=019ca4e5-63d7-728c-a1d5-8e5dcbffad85`
- `body_request_id=1e78b7cc-5b88-46e3-9106-8e4cef99f4b0`
- `function_version=assistant-context_v1.0.0`
- `contract_version=assistant-context_contract_v1`
- `metric_contract_present=false`
- `top_projects[0]` keys:
  - `project_id,project_name,phase,interactions_7d,active_journal_claims,open_loops,pending_reviews,striking_signal_count,risk_flag`

## Interpretation
- Live runtime is still pre-contract rollout (`assistant-context_v1.0.0`).
- Legacy ambiguous aliases are still present in production payload (`active_journal_claims`, `open_loops`, `pending_reviews`).
- This smoke capture is the pre-deploy baseline before rolling out the explicit metric contract update.

## Post-Deploy Verification
- Deployment command:
  - `supabase functions deploy assistant-context --project-ref rjhdwidddtfetbwqolof --no-verify-jwt`
- Capture at: `2026-02-28T15:42Z`
- `status_line=HTTP/2 200`
- `sb_request_id=019ca4e9-63e1-7507-b849-fe958a44e866`
- `body_request_id=62496d5f-62b3-4d62-8bdd-7d12301cc655`
- `function_version=assistant-context_v1.2.0`
- `contract_version=assistant_context_metric_contract_v3`
- `metric_contract_present=true`
- `top_projects[0]` keys:
  - `project_id,project_name,phase,interactions_7d,active_journal_claims_total,active_journal_claims_7d,open_loops_total,open_loops_7d,pending_reviews_span_total,pending_reviews_queue_total,pending_reviews_queue_7d,striking_signal_count,risk_flag`
- Alias removal check (`active_journal_claims`, `open_loops`, `pending_reviews` across `top_projects`):
  - `false` (aliases not present)

## Result
- Lane C assistant-context contract rollout is live.
- Payload now exposes explicit, non-ambiguous metric fields with contract metadata and request ID.
