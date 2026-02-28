# Redline Pipeline Harness Invariants v1 (DATA-1, 2026-02-28)

## Objective
Make Redline a harness for pipeline correctness, not just a UI. Every surfaced gap should quickly classify into one lane:
1. `ingestion_missing` (Beside has event, interactions does not)
2. `projection_missing` (interactions has event, redline projection does not)
3. `ui_gap` (projection exists, UX still fails)

## Canonical reachability chain
1. `public.beside_thread_events` is the external-event source signal for Beside timeline.
2. `public.interactions` is the normalized canonical interaction layer used by downstream features.
3. `public.redline_thread` is the projection used by Redline views.

Expected reachability for call-like events over 24h:
- `beside_thread_events(call*)` should map to `interactions(channel in call/phone)` via normalized phone + time window (±120s).
- `interactions(call/phone)` should map to `redline_thread(interaction_type like call%)` by `interaction_id`.

## Monitor invariants
1. Invariant A (ingestion parity):
- `beside_calls_missing_in_interactions_24h` should be near 0.
- Sustained non-zero means ingest drift or mapping key regression.

2. Invariant B (projection parity):
- `interactions_missing_in_redline_thread_24h` should be near 0.
- Non-zero means projection/view wiring drift.

3. Invariant C (alert discipline):
- Alert only when monitor thresholds breached.
- Monitor must include sample tuples/interaction_ids for direct repro.

## Implemented monitors
- `public.v_beside_calls_missing_in_interactions_24h`
  - One-row summary with `missing_count` + `example_tuples`.
- `public.v_interactions_missing_in_redline_thread_24h`
  - Detailed row-level list of missing `interaction_id`s and context.
- `public.run_beside_parity_monitor_v1(...)`
  - Writes `monitor_alerts` heartbeat/alert with counts + examples.
  - Optionally emits TRAM alert when above threshold.
- Cron:
  - `beside_parity_monitor_v1_15m` (`*/15 * * * *`)

## Operator-safe reconciliation guidance
Auto-safe (can run automatically):
1. Projection refresh/rebuild for Redline matviews when Invariant B fails and interactions rows are present.
2. Recompute contact/thread projection cache keyed by recent interaction_ids.

Operator-gated (manual escalation):
1. Beside ingest/mapping hotfix when Invariant A fails (events exist in Beside only).
2. Phone normalization and mapping rule changes affecting historical joins.
3. Backfills that could mutate attribution state across many rows.

## Practical triage decision tree
1. Beside tuple present, interactions absent:
- classify `ingestion_missing` -> ingest lane.
2. interactions present, redline_thread absent:
- classify `projection_missing` -> projection lane.
3. redline_thread present but user still cannot find it:
- classify `ui_gap` -> search/filter/render lane.
