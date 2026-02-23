-- Stopline: ensure call evidence coverage for interactions referenced by spans.
-- Goals:
-- 1) Backfill missing source_type='call' baseline evidence rows for active-span interactions in the last 24h.
-- 2) Enforce fail-closed invariant: inserting/updating conversation_spans must leave a durable
--    evidence_events row (payload_ref + integrity_hash) for that interaction.

begin;

-- 1) Deterministic 24h backfill for active spans.
with target_interactions as (
  select distinct cs.interaction_id
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
    and coalesce(cs.created_at, now()) >= (now() - interval '24 hours')
),
interaction_facts as (
  select
    t.interaction_id,
    coalesce(i.event_at_utc, cr.event_at_utc, i.ingested_at_utc, now()) as occurred_at_utc,
    cr.id as calls_raw_id,
    coalesce(cr.transcript, '') as transcript_text
  from target_interactions t
  left join public.interactions i
    on i.interaction_id = t.interaction_id
  left join lateral (
    select
      cr2.id,
      cr2.event_at_utc,
      cr2.transcript
    from public.calls_raw cr2
    where cr2.interaction_id = t.interaction_id
    order by cr2.event_at_utc desc nulls last, cr2.id desc
    limit 1
  ) cr on true
),
backfill as (
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
    f.interaction_id as source_id,
    'stopline_backfill:20260223009200' as source_run_id,
    'baseline' as transcript_variant,
    f.occurred_at_utc,
    coalesce(
      'calls_raw:' || f.calls_raw_id::text,
      'call_interaction:' || f.interaction_id || ':baseline'
    ) as payload_ref,
    encode(
      digest(f.interaction_id || '|baseline|' || coalesce(f.transcript_text, ''), 'sha256'),
      'hex'
    ) as integrity_hash,
    jsonb_build_object(
      'stopline', 'call_evidence_coverage',
      'source', 'migration_backfill',
      'migration', '20260223009200',
      'calls_raw_id', f.calls_raw_id
    ) as metadata
  from interaction_facts f
  on conflict (source_type, source_id, transcript_variant) do update
    set
      payload_ref = coalesce(public.evidence_events.payload_ref, excluded.payload_ref),
      integrity_hash = coalesce(public.evidence_events.integrity_hash, excluded.integrity_hash),
      occurred_at_utc = coalesce(public.evidence_events.occurred_at_utc, excluded.occurred_at_utc),
      source_run_id = coalesce(public.evidence_events.source_run_id, excluded.source_run_id),
      metadata = coalesce(public.evidence_events.metadata, '{}'::jsonb) || jsonb_build_object(
        'stopline_backfill_last_seen_at_utc',
        (now() at time zone 'utc')
      )
  returning source_id, evidence_event_id
)
select count(*)::int as stopline_call_evidence_backfilled_rows
from backfill;

-- 2) Fail-closed trigger for any span writer (segment-call, admin-reseed, or future pipelines).
create or replace function public.ensure_call_evidence_for_span_interaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_interaction_id text;
  v_interaction_exists boolean;
  v_calls_raw_id uuid;
  v_transcript text;
  v_occurred_at_utc timestamptz;
  v_payload_ref text;
  v_integrity_hash text;
begin
  v_interaction_id := new.interaction_id;

  if v_interaction_id is null or btrim(v_interaction_id) = '' then
    raise exception 'STOPLINE_EVIDENCE_EVENTS_MISSING_INTERACTION_ID';
  end if;

  select exists(
    select 1
    from public.interactions i
    where i.interaction_id = v_interaction_id
  )
  into v_interaction_exists;

  if not coalesce(v_interaction_exists, false) then
    raise exception 'STOPLINE_EVIDENCE_EVENTS_INTERACTION_NOT_FOUND interaction_id=%', v_interaction_id;
  end if;

  if exists (
    select 1
    from public.evidence_events ee
    where ee.source_type = 'call'
      and ee.source_id = v_interaction_id
      and coalesce(ee.transcript_variant, 'baseline') = 'baseline'
      and ee.payload_ref is not null
      and ee.integrity_hash is not null
  ) then
    return new;
  end if;

  select
    cr.id,
    coalesce(cr.transcript, ''),
    coalesce(i.event_at_utc, cr.event_at_utc, i.ingested_at_utc, now())
  into
    v_calls_raw_id,
    v_transcript,
    v_occurred_at_utc
  from public.interactions i
  left join lateral (
    select
      cr2.id,
      cr2.event_at_utc,
      cr2.transcript
    from public.calls_raw cr2
    where cr2.interaction_id = i.interaction_id
    order by cr2.event_at_utc desc nulls last, cr2.id desc
    limit 1
  ) cr on true
  where i.interaction_id = v_interaction_id
  limit 1;

  if v_occurred_at_utc is null then
    select
      cr.id,
      coalesce(cr.transcript, ''),
      coalesce(cr.event_at_utc, now())
    into
      v_calls_raw_id,
      v_transcript,
      v_occurred_at_utc
    from public.calls_raw cr
    where cr.interaction_id = v_interaction_id
    order by cr.event_at_utc desc nulls last, cr.id desc
    limit 1;
  end if;

  v_payload_ref := coalesce(
    'calls_raw:' || v_calls_raw_id::text,
    'call_interaction:' || v_interaction_id || ':baseline'
  );
  v_integrity_hash := encode(
    digest(v_interaction_id || '|baseline|' || coalesce(v_transcript, ''), 'sha256'),
    'hex'
  );

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
  values (
    'call',
    v_interaction_id,
    'stopline_guard:20260223009200',
    'baseline',
    coalesce(v_occurred_at_utc, now()),
    v_payload_ref,
    v_integrity_hash,
    jsonb_build_object(
      'stopline', 'call_evidence_coverage',
      'source', 'conversation_spans_trigger',
      'migration', '20260223009200',
      'calls_raw_id', v_calls_raw_id
    )
  )
  on conflict (source_type, source_id, transcript_variant) do update
    set
      payload_ref = coalesce(public.evidence_events.payload_ref, excluded.payload_ref),
      integrity_hash = coalesce(public.evidence_events.integrity_hash, excluded.integrity_hash),
      occurred_at_utc = coalesce(public.evidence_events.occurred_at_utc, excluded.occurred_at_utc),
      source_run_id = coalesce(public.evidence_events.source_run_id, excluded.source_run_id),
      metadata = coalesce(public.evidence_events.metadata, '{}'::jsonb) || jsonb_build_object(
        'stopline_guard_last_seen_at_utc',
        (now() at time zone 'utc')
      );

  if not exists (
    select 1
    from public.evidence_events ee
    where ee.source_type = 'call'
      and ee.source_id = v_interaction_id
      and coalesce(ee.transcript_variant, 'baseline') = 'baseline'
      and ee.payload_ref is not null
      and ee.integrity_hash is not null
  ) then
    raise exception 'STOPLINE_EVIDENCE_EVENTS_ENSURE_FAILED interaction_id=%', v_interaction_id;
  end if;

  return new;
exception
  when others then
    raise exception 'STOPLINE_EVIDENCE_EVENTS_ENSURE_FAILED interaction_id=% detail=%', v_interaction_id, sqlerrm;
end;
$$;

drop trigger if exists trg_conversation_spans_require_call_evidence
  on public.conversation_spans;

create trigger trg_conversation_spans_require_call_evidence
before insert or update of interaction_id
on public.conversation_spans
for each row
execute function public.ensure_call_evidence_for_span_interaction();

comment on function public.ensure_call_evidence_for_span_interaction is
'Stopline guard: span writes must have durable call evidence row with payload_ref+integrity_hash.';

commit;
