-- prod_test_fixture_pending_window_triage_backfill_v1.sql
--
-- Purpose:
-- - Close the DATA-4 "21 pending-window test fixture" lane with deterministic writes.
-- - Scope is intentionally narrow:
--   * interaction_id like 'cll_DEV5_CHAINFAIL_%' or 'cll_SMS_PROBE_%'
--   * span older than pending window
--   * review_queue status = pending
--   * span has no attribution yet
-- - For scoped rows only:
--   1) seed span_attributions row with decision='review'
--   2) upsert attribution_audit_ledger as test-fixture hard-drop failure
--   3) dismiss matching review_queue rows as test fixture triage
--
-- Usage:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--     -v pending_hours=2 \
--     -v max_age_days=7 \
--     -v actor='data-4' \
--     -f scripts/sql/prod_test_fixture_pending_window_triage_backfill_v1.sql

\set ON_ERROR_STOP on

\if :{?pending_hours}
\else
\set pending_hours 2
\endif

\if :{?max_age_days}
\else
\set max_age_days 7
\endif

\if :{?actor}
\else
\set actor 'data-4'
\endif

\echo 'Q1: preflight scope (seed-needed + ledger-needed in pending-window test fixtures)'
with target_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.created_at as span_created_at_utc,
    greatest(coalesce(cs.char_start, 0), 0) as char_start,
    greatest(
      coalesce(cs.char_end, greatest(coalesce(cs.char_start, 0) + 1, 1)),
      greatest(coalesce(cs.char_start, 0) + 1, 1)
    ) as char_end,
    md5(coalesce(cs.transcript_segment, '')) as transcript_span_hash,
    case
      when cs.interaction_id like 'cll_DEV5_CHAINFAIL_%' then 'DEV5_CHAINFAIL'
      when cs.interaction_id like 'cll_SMS_PROBE_%' then 'SMS_PROBE'
      else 'OTHER'
    end as id_bucket
  from public.conversation_spans cs
  where (
    cs.interaction_id like 'cll_DEV5_CHAINFAIL_%'
    or cs.interaction_id like 'cll_SMS_PROBE_%'
  )
    and cs.created_at >= now() - make_interval(days => (:'max_age_days')::int)
    and cs.created_at <= now() - make_interval(hours => (:'pending_hours')::int)
),
pending_missing as (
  select t.*
  from target_spans t
  where exists (
      select 1
      from public.review_queue rq
      where rq.span_id = t.span_id
        and rq.status = 'pending'
    )
    and not exists (
      select 1
      from public.span_attributions sa
      where sa.span_id = t.span_id
    )
),
existing_seeded_no_ledger as (
  select t.*
  from target_spans t
  join public.span_attributions sa
    on sa.span_id = t.span_id
   and sa.model_id = 'data4.manual.test_fixture'
   and sa.prompt_version = 'pending_window_triage_v1'
  where not exists (
    select 1
    from public.attribution_audit_ledger l
    where l.dedupe_key = md5('data4_test_fixture_pending_window:' || t.span_id::text)
  )
)
select
  (select count(*) from pending_missing)::int as seed_target_rows,
  (select count(*) from existing_seeded_no_ledger)::int as ledger_only_target_rows,
  (
    select count(*)
    from (
      select span_id from pending_missing
      union
      select span_id from existing_seeded_no_ledger
    ) u
  )::int as total_unique_target_rows,
  (select count(*) from pending_missing where id_bucket = 'DEV5_CHAINFAIL')::int as seed_dev5_chainfail_rows,
  (select count(*) from pending_missing where id_bucket = 'SMS_PROBE')::int as seed_sms_probe_rows,
  (
    select count(*)
    from (
      select span_created_at_utc from pending_missing
      union all
      select span_created_at_utc from existing_seeded_no_ledger
    ) d
  )::int as scoped_rows_for_timestamp_window,
  (
    select min(span_created_at_utc)
    from (
      select span_created_at_utc from pending_missing
      union all
      select span_created_at_utc from existing_seeded_no_ledger
    ) d
  ) as oldest_span_created_at_utc,
  (
    select max(span_created_at_utc)
    from (
      select span_created_at_utc from pending_missing
      union all
      select span_created_at_utc from existing_seeded_no_ledger
    ) d
  ) as newest_span_created_at_utc;

\echo 'APPLY: seed attribution + upsert ledger + dismiss review_queue'
begin;

with target_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.created_at as span_created_at_utc,
    greatest(coalesce(cs.char_start, 0), 0) as char_start,
    greatest(
      coalesce(cs.char_end, greatest(coalesce(cs.char_start, 0) + 1, 1)),
      greatest(coalesce(cs.char_start, 0) + 1, 1)
    ) as char_end,
    md5(coalesce(cs.transcript_segment, '')) as transcript_span_hash
  from public.conversation_spans cs
  where (
    cs.interaction_id like 'cll_DEV5_CHAINFAIL_%'
    or cs.interaction_id like 'cll_SMS_PROBE_%'
  )
    and cs.created_at >= now() - make_interval(days => (:'max_age_days')::int)
    and cs.created_at <= now() - make_interval(hours => (:'pending_hours')::int)
),
pending_missing as (
  select t.*
  from target_spans t
  where exists (
      select 1
      from public.review_queue rq
      where rq.span_id = t.span_id
        and rq.status = 'pending'
    )
    and not exists (
      select 1
      from public.span_attributions sa
      where sa.span_id = t.span_id
    )
),
seed_attr as (
  insert into public.span_attributions (
    span_id,
    project_id,
    confidence,
    attribution_source,
    attributed_at,
    attributed_by,
    decision,
    reasoning,
    anchors,
    prompt_version,
    model_id,
    needs_review,
    evidence_tier,
    top_candidates,
    candidate_count
  )
  select
    pm.span_id,
    null::uuid as project_id,
    null::numeric as confidence,
    'manual_test_fixture_backfill' as attribution_source,
    now() as attributed_at,
    :'actor' as attributed_by,
    'review' as decision,
    'DATA-4 pending-window triage backfill for non-prod test fixture' as reasoning,
    jsonb_build_array(
      jsonb_build_object(
        'type', 'test_fixture',
        'source', 'data4_pending_window_triage_v1'
      )
    ) as anchors,
    'pending_window_triage_v1' as prompt_version,
    'data4.manual.test_fixture' as model_id,
    true as needs_review,
    3 as evidence_tier,
    '[]'::jsonb as top_candidates,
    0::smallint as candidate_count
  from pending_missing pm
  on conflict (span_id, model_id, prompt_version)
  do update
    set
      decision = excluded.decision,
      needs_review = true,
      reasoning = excluded.reasoning,
      attribution_source = excluded.attribution_source,
      attributed_at = now(),
      attributed_by = excluded.attributed_by
  returning id, span_id
),
seeded_attrs as (
  select
    pm.span_id,
    pm.interaction_id,
    pm.span_created_at_utc,
    pm.char_start,
    pm.char_end,
    pm.transcript_span_hash,
    sa.id as span_attribution_id
  from pending_missing pm
  join seed_attr sa
    on sa.span_id = pm.span_id
),
existing_seeded_no_ledger as (
  select
    t.span_id,
    t.interaction_id,
    t.span_created_at_utc,
    t.char_start,
    t.char_end,
    t.transcript_span_hash,
    sa.id as span_attribution_id
  from target_spans t
  join public.span_attributions sa
    on sa.span_id = t.span_id
   and sa.model_id = 'data4.manual.test_fixture'
   and sa.prompt_version = 'pending_window_triage_v1'
  where not exists (
    select 1
    from public.attribution_audit_ledger l
    where l.dedupe_key = md5('data4_test_fixture_pending_window:' || t.span_id::text)
  )
),
ledger_scope as (
  select * from seeded_attrs
  union
  select * from existing_seeded_no_ledger
),
ledger_payload as (
  select
    sa.*,
    coalesce(cr.event_at_utc, sa.span_created_at_utc) as t_call_utc,
    jsonb_build_object(
      'source', 'data4_pending_window_triage',
      'lane', 'test_fixture_hard_drop_pending_window',
      'actor', :'actor',
      'interaction_id', sa.interaction_id,
      'span_id', sa.span_id::text,
      'notes', 'Backfill for test fixture span that exceeded pending window without attribution.'
    ) as packet_json
  from ledger_scope sa
  left join public.calls_raw cr
    on cr.interaction_id = sa.interaction_id
),
ledger_upsert as (
  insert into public.attribution_audit_ledger (
    dedupe_key,
    span_attribution_id,
    span_id,
    interaction_id,
    assigned_project_id,
    assigned_decision,
    assigned_confidence,
    attribution_source,
    evidence_tier,
    t_call_utc,
    asof_mode,
    same_call_excluded,
    evidence_event_ids,
    span_char_start,
    span_char_end,
    transcript_span_hash,
    packet_json,
    packet_hash,
    reviewer_provider,
    reviewer_model,
    reviewer_prompt_version,
    reviewer_temperature,
    reviewer_run_id,
    verdict,
    top_candidates,
    competing_margin,
    failure_tags,
    missing_evidence,
    leakage_violation,
    pointer_quality_violation,
    failure_mode_bucket,
    failure_detail,
    auditor_model_id,
    auditor_prompt_version,
    resolution_metadata
  )
  select
    md5('data4_test_fixture_pending_window:' || lp.span_id::text) as dedupe_key,
    lp.span_attribution_id,
    lp.span_id,
    lp.interaction_id,
    null::uuid as assigned_project_id,
    'review' as assigned_decision,
    null::numeric as assigned_confidence,
    'manual_test_fixture_backfill' as attribution_source,
    3 as evidence_tier,
    lp.t_call_utc,
    'KNOWN_AS_OF' as asof_mode,
    true as same_call_excluded,
    '{}'::uuid[] as evidence_event_ids,
    lp.char_start as span_char_start,
    lp.char_end as span_char_end,
    lp.transcript_span_hash,
    lp.packet_json,
    md5(lp.packet_json::text) as packet_hash,
    'manual' as reviewer_provider,
    'data4_pending_window_triage_v1' as reviewer_model,
    'data4_pending_window_triage_v1' as reviewer_prompt_version,
    null::numeric as reviewer_temperature,
    'data4_pending_window_triage_v1' as reviewer_run_id,
    'INSUFFICIENT' as verdict,
    '[]'::jsonb as top_candidates,
    null::numeric as competing_margin,
    array['insufficient_provenance_pointer_quality']::text[] as failure_tags,
    array['test_fixture_pending_window_no_evidence']::text[] as missing_evidence,
    false as leakage_violation,
    true as pointer_quality_violation,
    'test_fixture_hard_drop_pending_window' as failure_mode_bucket,
    'Backfilled pending-window test fixture without usable evidence events.' as failure_detail,
    'data4_pending_window_triage_v1' as auditor_model_id,
    'data4_pending_window_triage_v1' as auditor_prompt_version,
    jsonb_build_object(
      'origin', 'data4_pending_window_triage_v1',
      'actor', :'actor'
    ) as resolution_metadata
  from ledger_payload lp
  on conflict (dedupe_key)
  do update
    set
      hit_count = public.attribution_audit_ledger.hit_count + 1,
      last_seen_at_utc = now(),
      pointer_quality_violation = excluded.pointer_quality_violation,
      failure_mode_bucket = excluded.failure_mode_bucket,
      failure_detail = excluded.failure_detail,
      failure_tags = excluded.failure_tags,
      missing_evidence = excluded.missing_evidence,
      resolution_metadata = excluded.resolution_metadata
  returning id, span_id
),
rq_dismiss as (
  update public.review_queue rq
  set
    status = 'dismissed',
    resolved_at = coalesce(rq.resolved_at, now()),
    resolved_by = coalesce(rq.resolved_by, :'actor'),
    resolution_action = 'auto_dismiss',
    resolution_notes = coalesce(rq.resolution_notes, '')
      || case
        when coalesce(rq.resolution_notes, '') = '' then ''
        else E'\n'
      end
      || 'data4 pending-window triage: test fixture backfill',
    requires_reprocess = false,
    updated_at = now()
  where rq.status = 'pending'
    and rq.span_id in (select span_id from pending_missing)
  returning rq.id, rq.span_id
)
select
  (select count(*) from pending_missing)::int as target_rows,
  (select count(*) from seed_attr)::int as seeded_attr_rows,
  (select count(*) from ledger_scope)::int as ledger_scope_rows,
  (select count(*) from ledger_upsert)::int as ledger_rows_upserted,
  (select count(*) from rq_dismiss)::int as review_queue_dismissed_rows;

commit;

\echo 'Q3: post-check (remaining pending-window rows in scoped test fixtures)'
with target_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.created_at as span_created_at_utc,
    case
      when cs.interaction_id like 'cll_DEV5_CHAINFAIL_%' then 'DEV5_CHAINFAIL'
      when cs.interaction_id like 'cll_SMS_PROBE_%' then 'SMS_PROBE'
      else 'OTHER'
    end as id_bucket
  from public.conversation_spans cs
  where (
    cs.interaction_id like 'cll_DEV5_CHAINFAIL_%'
    or cs.interaction_id like 'cll_SMS_PROBE_%'
  )
    and cs.created_at >= now() - make_interval(days => (:'max_age_days')::int)
    and cs.created_at <= now() - make_interval(hours => (:'pending_hours')::int)
),
pending_missing as (
  select t.*
  from target_spans t
  where exists (
      select 1
      from public.review_queue rq
      where rq.span_id = t.span_id
        and rq.status = 'pending'
    )
    and not exists (
      select 1
      from public.span_attributions sa
      where sa.span_id = t.span_id
    )
)
select
  count(*)::int as pending_rows_after,
  count(*) filter (where id_bucket = 'DEV5_CHAINFAIL')::int as dev5_chainfail_rows_after,
  count(*) filter (where id_bucket = 'SMS_PROBE')::int as sms_probe_rows_after
from pending_missing;

\echo 'Q4: ledger confirmation for triage bucket'
select
  count(*)::int as ledger_rows_in_bucket,
  count(distinct span_id)::int as distinct_spans_in_bucket,
  min(created_at) as oldest_row_utc,
  max(created_at) as newest_row_utc
from public.attribution_audit_ledger
where failure_mode_bucket = 'test_fixture_hard_drop_pending_window'
  and (
    interaction_id like 'cll_DEV5_CHAINFAIL_%'
    or interaction_id like 'cll_SMS_PROBE_%'
  )
  and created_at >= now() - make_interval(days => (:'max_age_days')::int);
