-- Stopline: backfill source_type='call' evidence rows for interactions that already
-- have active conversation spans but no call evidence pointer.
--
-- Scope: last 24 hours of active spans (mirrors stopline proof window).

with target_interactions as (
  select distinct
    cs.interaction_id,
    coalesce(i.event_at_utc, cr.event_at_utc, now()) as occurred_at_utc,
    cr.id as calls_raw_id,
    coalesce(cr.transcript, '') as transcript_text
  from public.conversation_spans cs
  left join public.interactions i
    on i.interaction_id = cs.interaction_id
  left join public.calls_raw cr
    on cr.interaction_id = cs.interaction_id
  where cs.is_superseded = false
    and coalesce(cs.created_at, now()) >= now() - interval '24 hours'
),
missing as (
  select t.*
  from target_interactions t
  where not exists (
    select 1
    from public.evidence_events ee
    where ee.source_type = 'call'
      and ee.source_id = t.interaction_id
      and coalesce(ee.transcript_variant, 'baseline') = 'baseline'
  )
),
inserted as (
  insert into public.evidence_events (
    source_type,
    source_id,
    source_run_id,
    transcript_variant,
    occurred_at_utc,
    payload_ref,
    integrity_hash,
    metadata
  )
  select
    'call' as source_type,
    m.interaction_id as source_id,
    'backfill:20260223009100' as source_run_id,
    'baseline' as transcript_variant,
    m.occurred_at_utc,
    coalesce(
      'calls_raw:' || m.calls_raw_id::text,
      'call_interaction:' || m.interaction_id || ':baseline'
    ) as payload_ref,
    encode(
      digest(m.interaction_id || '|baseline|' || coalesce(m.transcript_text, ''), 'sha256'),
      'hex'
    ) as integrity_hash,
    jsonb_build_object(
      'backfill', 'call_evidence_coverage_stopline',
      'migration', '20260223009100',
      'calls_raw_id', m.calls_raw_id
    ) as metadata
  from missing m
  on conflict (source_type, source_id, transcript_variant) do nothing
  returning source_id, evidence_event_id
)
select count(*)::int as inserted_call_evidence_rows
from inserted;
