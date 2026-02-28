# DATA-1 Bundle Status (2026-02-28)

## 1) In-app Assistant + Context Packet (LLM-first)

### Delivered
- DB contract migrated and applied:
  - `supabase/migrations/20260228054500_redefine_v_project_feed_metric_contract.sql`
  - `supabase/migrations/20260228054600_extend_v_review_queue_summary_with_7d_windows.sql`
  - `supabase/migrations/20260228054700_redefine_v_who_needs_you_today_recency_contract.sql`
- Edge payload updated:
  - `supabase/functions/assistant-context/index.ts`
  - `FUNCTION_VERSION`: `assistant-context_v1.1.0`
- `assistant-context` now preserves legacy keys but maps display aliases to windowed values:
  - `active_journal_claims` => `active_journal_claims_7d`
  - `open_loops` => `open_loops_7d`
  - `pending_reviews` => `pending_reviews_queue_7d`
- Added explicit contract payload:
  - `metric_contract.version = assistant_context_metric_contract_v2`

### DB proof (Woodbery/Moss)
- Proof SQL: `scripts/sql/assistant_context_packet_numbers_proof_20260228.sql`
- Current contract rows in `v_project_feed`:
  - Woodbery: claims total/7d = `1581/620`, loops total/7d = `128/126`, reviews span/queue = `69/28`
  - Moss: claims total/7d = `157/102`, loops total/7d = `17/16`, reviews span/queue = `88/22`

## 2) Pipeline-wide model config rollout (runtime reality check)

### Evidence
- DB config inventory: `scripts/sql/pipeline_model_config_runtime_audit_20260228.sql`
  - `pipeline_model_config`: 16 functions configured.
- Code adoption scan:
  - Using shared runtime config helper (`getModelConfigCached`): `ai-router`, `journal-extract`, `segment-llm`
  - Still hardcoded/env-model patterns found: `generate-summary`, `striking-detect`, `chain-detect`, `decision-auditor`, `evidence-assembler` (and others via static model constants)
- Recent DB footprints:
  - `span_attributions` in last 24h from `ai-router-v1.19.0` on `gpt-4o-mini` and fallback `claude-3-haiku-20240307`
  - `journal_claims.extraction_model_id` last 24h: `gpt-4o-mini`

### Conclusion
- Runtime config is active for the 3 helper-adopted functions.
- Runtime config is **not yet universally enforced** across all configured functions.
- Temperature-effect proof remains partial where functions do not persist temp/model metadata per invocation.

## 3) Pipeline health incidents (DATA lane)

### Snapshot
- Proof SQL: `scripts/sql/pipeline_health_incidents_snapshot_20260228.sql`
- Hard-drop monitor: `pending_total=367`, `sla_breach_count=240`, `48h+=205`.
- Composition of pending:
  - `pending_with_review_queue=344`
  - `pending_without_review_queue=24`
- `v_span_sla_summary` shows `breached_count=0` because it tracks uncovered spans only (different contract than hard-drop monitor).
- Redline monitor alerting:
  - `redline_refresh_monitor_v1` currently alerting on `journal_stale=true`.
- Freshness:
  - `journal_claims` and `journal_open_loops` ~7.6h stale.
  - Interactions continued after last journal claim:
    - `interactions_since_last_claim=15`
    - `interactions_without_claims=15`

### Conclusion
- Hard-drop and span-SLA are not contradictory; they measure different classes.
- Real incident is journal extraction lag after fresh interactions.

## 4) Overwritten versions audit (1–2 generations back)

### Snapshot
- Proof SQL: `scripts/sql/overwritten_generation_audit_20260228.sql`
- `conversation_spans`:
  - total `2851`, superseded `1333` (`46.76%`)
  - generation buckets: latest `1687`, one_back `452`, two_plus_back `712`
- Interaction-level:
  - max gen >=2: `136/440`
  - max gen >=3: `67/440`
  - max gen >=4: `50/440`
- Recoverability and blast radius:
  - superseded rows without active replacement: `235`
  - latest-generation rows already superseded: `170`
  - pending review rows on superseded spans: `5/403`
  - attributions on superseded spans: `1333/3086`
  - one anomaly: active non-latest row (`cll_06DSX0CVZHZK72VCVW54EH9G3C`, span 0, gen 1 while max gen 6)

### Conclusion
- High supersede volume is expected in reseed/regeneration workflows, but no active-replacement gaps and superseded-latest rows are non-trivial and should be monitored as integrity debt.

## 5) Owner split (next)
- DATA:
  - Add integrity monitor for:
    - `latest_rows_superseded > 0`
    - `superseded_without_active_replacement > 0`
    - `active_not_latest_rows > 0`
  - Add monitor output section explicitly separating:
    - hard-drop pending under review
    - hard-drop pending uncovered
- DEV (dev-2):
  - Update iOS labels/UI to render explicit metric names or show tooltip:
    - claims (7d), loops (7d), reviews (pending queue 7d)
  - Consider hiding span-review total unless in debug mode.

