# Assistant Context Data Quality Fix Plan (2026-02-28)

## Scope
- Receipt: `p0__assistant_context_packet_data_quality_defs_top_projects_reviews_claims_loops__20260228`
- Source proof query: `scripts/sql/assistant_context_packet_numbers_proof_20260228.sql`
- Target projects validated: `Woodbery Residence`, `Moss Residence`

## Field Definitions (Current)
- `calls` (`v_project_feed.interactions_7d`)
  - Source: `interactions` where `event_at_utc >= now() - interval '7 days'`
  - Status: correct and already windowed.
- `claims` (`v_project_feed.active_journal_claims`)
  - Source: `journal_claims` where `active=true` (lifetime active, no time window).
  - Status: not wrong, but unit/window is implicit and easily misread as recent activity.
- `loops` (`v_project_feed.open_loops`)
  - Source: `journal_open_loops` where `status='open'` (lifetime open backlog).
  - Status: not wrong, but not window-aligned to calls.
- `reviews` (`v_project_feed.pending_reviews`)
  - Source: `span_attributions.needs_review=true` joined through `conversation_spans` to project interactions.
  - Status: misleading for operator backlog; does not represent pending `review_queue`.

## DB Proof Snapshot
- Woodbery Residence:
  - `interactions_7d=33`
  - `active_journal_claims=1581` (lifetime), `claims_active_7d=620`
  - `open_loops=128` (lifetime), `open_loops_7d=126`
  - `pending_reviews=69` (`span_attributions.needs_review`)
  - `review_queue_pending_total=28`, `review_queue_pending_7d=28`
- Moss Residence:
  - `interactions_7d=3`
  - `active_journal_claims=157` (lifetime), `claims_active_7d=102`
  - `open_loops=17` (lifetime), `open_loops_7d=16`
  - `pending_reviews=88` (`span_attributions.needs_review`)
  - `review_queue_pending_total=22`, `review_queue_pending_7d=22`
- `v_review_queue_summary` is global-only (single row), not project-scoped.
- `v_who_needs_you_today` mixes recent claims (5-day filters) with open blockers that currently have no recency filter.

## Proposed Contract (Sane + Explicit)
- `v_project_feed` should expose both totals and windowed values with explicit names:
  - `active_journal_claims_total`, `active_journal_claims_7d`
  - `open_loops_total`, `open_loops_7d`
  - `pending_reviews_span_total` (current span-attribution metric)
  - `pending_reviews_queue_total`, `pending_reviews_queue_7d` (operator backlog metric)
- Assistant context should present window-aligned numbers:
  - `calls = interactions_7d`
  - `claims = active_journal_claims_7d`
  - `loops = open_loops_7d`
  - `reviews = pending_reviews_queue_7d` (or `_total` if product chooses backlog over velocity)
- `v_review_queue_summary` should include explicit windows:
  - keep current global totals
  - add `pending_total_7d`, `pending_attribution_7d`, `pending_weak_anchor_7d`, `pending_coverage_gap_7d`
- `v_who_needs_you_today` should enforce recency for blocker-derived rows (7-day window) or be renamed if intentionally backlog-wide.

## Proposed Migration Filenames
- `supabase/migrations/20260228054500_redefine_v_project_feed_metric_contract.sql`
- `supabase/migrations/20260228054600_extend_v_review_queue_summary_with_7d_windows.sql`
- `supabase/migrations/20260228054700_redefine_v_who_needs_you_today_recency_contract.sql`
- `supabase/migrations/20260228054800_update_assistant_context_to_windowed_metrics.sql`

## Rollout Notes
- Backward compatibility:
  - Keep existing columns during transition.
  - Add explicit columns first, then switch edge function to explicit windowed fields.
- Verification:
  - Re-run `scripts/sql/assistant_context_packet_numbers_proof_20260228.sql`.
  - Confirm assistant context top-project cards no longer show lifetime/backlog metrics as if recent.
