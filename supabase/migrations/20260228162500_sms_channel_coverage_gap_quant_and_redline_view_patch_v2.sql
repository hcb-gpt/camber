-- P0 attribution architecture fix: quantify sms coverage gap + patch sms thread surface
-- Receipt: p0_attrib_arch_fix__sms_channel_coverage_gap_quant_and_view_patch__20260228

begin;

create or replace view public.v_channel_span_attribution_gap_daily as
with base as (
  select
    date_trunc('day', i.event_at_utc)::date as event_date_utc,
    i.channel,
    i.interaction_id,
    exists (
      select 1
      from public.conversation_spans cs
      where cs.interaction_id = i.interaction_id
        and coalesce(cs.is_superseded, false) = false
    ) as has_spans,
    coalesce(vip.primary_project_id, i.project_id) as effective_project_id
  from public.interactions i
  left join public.v_interaction_primary_project vip
    on vip.interaction_id = i.interaction_id
  where i.event_at_utc >= now() - interval '90 days'
)
select
  b.event_date_utc,
  b.channel,
  count(*)::int as interactions_total,
  count(*) filter (where b.has_spans)::int as interactions_with_spans,
  count(*) filter (where not b.has_spans)::int as interactions_without_spans,
  count(*) filter (where b.effective_project_id is not null)::int as interactions_with_effective_project,
  count(*) filter (where b.effective_project_id is null)::int as interactions_without_effective_project,
  count(*) filter (where b.has_spans and b.effective_project_id is not null)::int
    as interactions_with_spans_and_effective_project,
  count(*) filter (where not b.has_spans and b.effective_project_id is null)::int
    as interactions_without_spans_and_effective_project
from base b
group by b.event_date_utc, b.channel
order by b.event_date_utc desc, b.channel;

comment on view public.v_channel_span_attribution_gap_daily is
'Daily channel coverage metrics: interactions with/without spans and with/without effective project attribution.';

create or replace view public.v_redline_sms_thread_v2 as
select
  s.id as sms_id,
  s.thread_id,
  s.sent_at as event_at_utc,
  s.sent_at as event_at_local,
  'sms'::text as interaction_type,
  s.direction,
  c.id as contact_id,
  s.contact_name,
  s.contact_phone,
  null::integer as duration_seconds,
  s.content as summary,
  rq_pending.span_id,
  null::integer as span_index,
  s.content as transcript_segment,
  case
    when s.direction = 'inbound' then s.contact_name
    else 'Chad'
  end as speaker_label,
  case
    when s.direction = 'inbound' then c.id
    else null::uuid
  end as speaker_contact_id,
  null::uuid as claim_id,
  null::text as claim_type,
  null::text as claim_text,
  null::text as span_text,
  null::text as confirmation_state,
  null::uuid as grade_id,
  null::text as grade,
  null::text as correction_text,
  null::text as graded_by,
  null::timestamptz as graded_at,
  rq_pending.id as review_queue_id,
  (rq_pending.id is not null) as needs_attribution,
  sms_thread_match.interaction_id as sms_thread_interaction_id,
  coalesce(vip.primary_project_id, sms_thread_match.project_id) as effective_project_id,
  case
    when vip.primary_project_id is not null then 'v_interaction_primary_project'
    when sms_thread_match.project_id is not null then 'interactions.project_id'
    else null
  end as effective_project_source
from public.sms_messages s
left join public.contacts c
  on c.phone = s.contact_phone
left join lateral (
  select
    rq.id,
    rq.span_id,
    rq.created_at
  from public.review_queue rq
  where rq.status = 'pending'
    and (
      rq.interaction_id = any (
        array[
          ('sms_thread_' || regexp_replace(coalesce(s.contact_phone, ''), '\\D', '', 'g') || '_' || floor(extract(epoch from s.sent_at))::bigint::text),
          ('sms_thread__' || floor(extract(epoch from s.sent_at))::bigint::text)
        ]
      )
    )
  order by rq.created_at desc
  limit 1
) rq_pending on true
left join lateral (
  select
    i.interaction_id,
    i.project_id,
    coalesce(i.event_at_utc, i.ingested_at_utc) as interaction_at_utc
  from public.interactions i
  where i.channel = 'sms_thread'
    and right(regexp_replace(coalesce(i.contact_phone, ''), '\D', '', 'g'), 10) =
      right(
        regexp_replace(
          coalesce(
            s.contact_phone,
            nullif(regexp_replace(coalesce(s.thread_id, ''), '^beside_sms_', ''), '')
          ),
          '\D',
          '',
          'g'
        ),
        10
      )
    and right(
      regexp_replace(
        coalesce(
          s.contact_phone,
          nullif(regexp_replace(coalesce(s.thread_id, ''), '^beside_sms_', ''), '')
        ),
        '\D',
        '',
        'g'
      ),
      10
    ) <> ''
  order by
    abs(extract(epoch from (coalesce(i.event_at_utc, i.ingested_at_utc) - s.sent_at))),
    coalesce(i.event_at_utc, i.ingested_at_utc) desc
  limit 1
) sms_thread_match on true
left join public.v_interaction_primary_project vip
  on vip.interaction_id = sms_thread_match.interaction_id
where exists (
  select 1
  from public.sms_messages s2
  where s2.contact_phone is not distinct from s.contact_phone
    and s2.direction = 'inbound'
);

comment on view public.v_redline_sms_thread_v2 is
'Patch view: SMS thread surface with effective_project_id preferring v_interaction_primary_project from thread-matched sms_thread interactions.';

commit;
