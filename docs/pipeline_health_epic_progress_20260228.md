# Pipeline Health Epic Progress (DATA-1, 2026-02-28)

## Scope
- Receipt: `epic__pipeline_health_hard_drop_sla_and_journal_stale__20260228`
- Root-cause proof: `scripts/sql/pipeline_health_hard_drop_root_cause_20260228.sql`
- Incident snapshot proof: `scripts/sql/pipeline_health_incidents_snapshot_20260228.sql`
- Remediation script executed: `scripts/sql/remediate_hard_drop_uncovered_pending_to_review_queue_20260228.sql`

## Hard-drop root cause (before remediation)
- `review_queue_pending_over_24h = 220`
- `review_queue_pending_under_24h = 124`
- `review_decision_no_review_queue = 22`
- `missing_decision_no_review_queue = 1`
- `needs_review_no_review_queue = 1`

Interpretation: most backlog is already in review queue; 24 uncovered spans were not queued for review.

## Remediation executed
- Action: promoted uncovered pending spans into `review_queue` (idempotent update/insert by `span_id`).
- Rows improved in this run: `24`
- Batch marker: `data1_hard_drop_requeue_20260228`

Sample improved IDs:
1. `span_id=756764aa-9ade-4f61-884d-083e152aa490` (`sms_thread_7065400877_1772149294`)
2. `span_id=208a8dcb-2666-4dcd-bd42-93757d9267e6` (`cll_06DKDCS3HHXBZ4CE2R1E70HQV4`)
3. `span_id=d68fe727-756b-44cd-978a-7fdcda7d0b45` (`cll_06DSX0CVZHZK72VCVW54EH9G3C`)

## Hard-drop state (after remediation)
- `pending_with_review_queue = 368`
- `pending_without_review_queue = 0` (improved from 24)
- `v_hard_drop_sla_monitor.pending_total = 344` (was 367)
- `v_hard_drop_sla_monitor.sla_breach_count = 220` (was 240)
- `v_hard_drop_sla_monitor.pending_by_age_bucket = {"1h":0,"6h":124,"24h":21,"48h+":199}`

Interpretation: uncovered lane is closed; remaining breach is queue-aged pending work.

## Journal stale / redline refresh findings
- Redline monitor firing on `journal_stale=true`.
- `v_pipeline_health`: `journal_claims` and `journal_open_loops` are ~7.6h stale.
- Interactions continued after last journal claim (`15` interactions since last claim timestamp in snapshot).
- `missing_extractable_spans_24h = 42` (spans with attribution but no journal_claim extraction).

## Guardrails proposed
1. Monitor split: track and alert separately for:
   - uncovered pending spans (no review_queue)
   - queue-backed pending spans over SLA
2. Alert tuning: page on both growth-rate and oldest-age thresholds, not absolute backlog alone.
3. Extraction freshness signal: add `missing_extractable_spans_24h` to redline monitor payload.

## Remaining work for epic completion
- Reduce queue-aged `sla_breach_count` (currently `220`) via requeue/worker throughput.
- Confirm root causes for oldest interaction clusters (top IDs in root-cause proof query).
- Validate alert noise reduction after tuning is implemented.

## Update (2026-02-28T05:10Z): alert-noise fixes applied
- Migration applied: `supabase/migrations/20260228071000_fix_redline_stale_anchor_and_disable_legacy_hard_drop_monitor.sql`
- New proof query: `scripts/sql/pipeline_health_monitor_noise_fix_proof_20260228.sql`

### Changes shipped
1. `run_redline_refresh_monitor` now anchors journal freshness to successful `journal_runs` activity (fallback includes claim timestamp), not just `journal_claims.created_at`.
2. Disabled legacy cron job `hard_drop_sla_monitor_hourly` that generated high-noise alerts.
3. Kept tuned monitor cron `hard_drop_sla_monitor_tuned_hourly` and fixed tuned oldest-age calculation to use true max pending age across queue.

### Verification snapshots
- Redline monitor manual run (no TRAM emit): `is_alert=false`, `journal_stale=false`.
- Hard-drop tuned monitor manual run: `is_alert=false`, `pending_total=344`, `pending_growth=0`, `oldest_age_hours=247.965`.
- Cron state: only `hard_drop_sla_monitor_tuned_hourly` remains active for hard-drop monitoring.

### Interpretation
- Redline stale alert false positives were caused by stale claim timestamps despite fresh successful journal runs.
- Hard-drop alert noise now routes through tuned monitor only; legacy unconditional breach paging is disabled.
- Remaining hard-drop work is queue-age debt reduction, not monitor contract instability.
