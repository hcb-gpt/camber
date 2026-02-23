-- attribution_audit_packet_v1.sql
--
-- Purpose:
-- - Build self-contained attribution audit packets (one JSON object per selected span)
-- - Enforce known-as-of world-model filtering and same-call exclusion
--
-- Inputs (psql vars):
-- - sample_seed    (float, optional)
-- - sample_limit   (int, default 10)
-- - lookback_hours (int, default 48)
--
-- Safe execution (read-only):
--   scripts/query.sh --file scripts/sql/attribution_audit_packet_v1.sql
--
-- Seeded execution:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--     -v sample_seed=0.314159 -v sample_limit=1 -v lookback_hours=48 \
--     -f scripts/sql/attribution_audit_packet_v1.sql

\if :{?sample_limit}
\else
\set sample_limit 10
\endif

\if :{?lookback_hours}
\else
\set lookback_hours 48
\endif

\if :{?sample_seed}
select setseed((:'sample_seed')::double precision);
select (:'sample_seed')::double precision as sample_seed_used;
\else
select null::double precision as sample_seed_used;
\endif

with latest_attr_per_span as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.span_index,
    cs.char_start,
    cs.char_end,
    cs.time_start_sec,
    cs.time_end_sec,
    cs.transcript_segment,
    cs.created_at as span_created_at,
    i.event_at_utc as interaction_event_at_utc,
    cr.event_at_utc as calls_raw_event_at_utc,
    i.contact_id,
    i.contact_phone,
    sa.id as span_attribution_id,
    coalesce(sa.applied_project_id, sa.project_id) as attributed_project_id,
    null::uuid as attribution_evidence_event_id,
    sa.decision,
    sa.needs_review,
    sa.attribution_lock,
    sa.attribution_source,
    sa.confidence,
    sa.applied_at_utc,
    sa.attributed_at,
    row_number() over (
      partition by cs.id
      order by coalesce(sa.applied_at_utc, sa.attributed_at, cs.created_at) desc, sa.id desc
    ) as rn
  from public.conversation_spans cs
  join public.span_attributions sa
    on sa.span_id = cs.id
  left join public.interactions i
    on i.interaction_id = cs.interaction_id
  left join public.calls_raw cr
    on cr.interaction_id = cs.interaction_id
  where cs.is_superseded = false
    and coalesce(sa.applied_project_id, sa.project_id) is not null
    and coalesce(sa.applied_at_utc, sa.attributed_at, cs.created_at)
      >= now() - make_interval(hours => (:'lookback_hours')::int)
),
sampled as (
  select
    l.*,
    coalesce(
      l.interaction_event_at_utc,
      l.calls_raw_event_at_utc,
      l.applied_at_utc,
      l.attributed_at,
      l.span_created_at
    ) as call_time_utc,
    regexp_replace(coalesce(l.contact_phone, ''), '\D', '', 'g') as contact_phone_digits
  from latest_attr_per_span l
  where l.rn = 1
  order by random()
  limit (:'sample_limit')::int
)
select
  jsonb_build_object(
    'span',
    jsonb_build_object(
      'span_id', s.span_id,
      'interaction_id', s.interaction_id,
      'span_index', s.span_index,
      'char_start', s.char_start,
      'char_end', s.char_end,
      'time_start_sec', s.time_start_sec,
      'time_end_sec', s.time_end_sec
    ),
    'attribution',
    jsonb_build_object(
      'attributed_project_id', s.attributed_project_id,
      'evidence_event_id', s.attribution_evidence_event_id,
      'decision', s.decision,
      'needs_review', s.needs_review,
      'attribution_lock', s.attribution_lock,
      'attribution_source', s.attribution_source,
      'confidence', s.confidence,
      'span_attribution_id', s.span_attribution_id
    ),
    'span_text',
    jsonb_build_object(
      'text', s.transcript_segment,
      'text_md5', md5(coalesce(s.transcript_segment, '')),
      'pointer',
      jsonb_build_object(
        'table', 'public.conversation_spans',
        'span_id', s.span_id,
        'interaction_id', s.interaction_id,
        'span_index', s.span_index,
        'char_start', s.char_start,
        'char_end', s.char_end
      )
    ),
    'evidence_ptrs', coalesce(ev.evidence_event_ids, '[]'::jsonb),
    'as_of_world_model',
    jsonb_build_object(
      'mode', 'KNOWN_AS_OF',
      'same_call_excluded', true,
      'call_time_utc', s.call_time_utc,
      'assigned_project_facts', coalesce(pf.assigned_project_facts, '[]'::jsonb)
    ),
    'candidates',
    case
      when ac.alias_candidate_count > 0 then ac.alias_candidates
      when fc.fallback_candidate_count > 0 then fc.fallback_candidates
      else '[]'::jsonb
    end,
    'candidate_generation_note',
    case
      when ac.alias_candidate_count > 0 then 'alias_overlap_v_project_alias_lookup'
      when fc.fallback_candidate_count > 0 then 'fallback_contact_history'
      else 'no_candidate_signal_found'
    end
  ) as audit_packet
from sampled s
left join lateral (
  select
    jsonb_agg(ee.evidence_event_id order by ee.occurred_at_utc desc, ee.evidence_event_id) as evidence_event_ids
  from public.evidence_events ee
  where ee.source_id = s.interaction_id
) ev on true
left join lateral (
  select
    jsonb_agg(
      jsonb_build_object(
        'id', pf.id,
        'project_id', pf.project_id,
        'fact_kind', pf.fact_kind,
        'as_of_at', pf.as_of_at,
        'observed_at', pf.observed_at,
        'interaction_id', pf.interaction_id,
        'evidence_event_id', pf.evidence_event_id,
        'source_span_id', pf.source_span_id,
        'source_char_start', pf.source_char_start,
        'source_char_end', pf.source_char_end,
        'fact_payload', pf.fact_payload
      )
      order by pf.as_of_at desc nulls last, pf.observed_at desc nulls last, pf.id
    ) as assigned_project_facts
  from public.project_facts pf
  where pf.project_id = s.attributed_project_id
    and (pf.as_of_at is null or pf.as_of_at <= s.call_time_utc)
    and (pf.observed_at is null or pf.observed_at <= s.call_time_utc)
    and pf.interaction_id is distinct from s.interaction_id
    and (
      s.attribution_evidence_event_id is null
      or pf.evidence_event_id is null
      or pf.evidence_event_id <> s.attribution_evidence_event_id
    )
) pf on true
left join lateral (
  select
    count(*)::int as alias_candidate_count,
    jsonb_agg(
      jsonb_build_object(
        'project_id', ranked.project_id,
        'project_name', ranked.project_name,
        'alias_hits', ranked.alias_hits,
        'alias_score', ranked.alias_score
      )
      order by ranked.alias_hits desc, ranked.alias_score desc, ranked.project_name
    ) as alias_candidates
  from (
    select
      val.project_id,
      p.name as project_name,
      count(*)::int as alias_hits,
      sum(char_length(val.alias))::int as alias_score
    from public.v_project_alias_lookup val
    join public.projects p
      on p.id = val.project_id
    where val.project_id is distinct from s.attributed_project_id
      and char_length(trim(val.alias)) >= 3
      and position(lower(val.alias) in lower(coalesce(s.transcript_segment, ''))) > 0
    group by val.project_id, p.name
    order by alias_hits desc, alias_score desc, p.name
    limit 5
  ) ranked
) ac on true
left join lateral (
  select
    count(*)::int as fallback_candidate_count,
    jsonb_agg(
      jsonb_build_object(
        'project_id', ranked.project_id,
        'project_name', ranked.project_name,
        'supporting_spans', ranked.supporting_spans,
        'last_seen_at_utc', ranked.last_seen_at_utc
      )
      order by ranked.supporting_spans desc, ranked.last_seen_at_utc desc nulls last
    ) as fallback_candidates
  from (
    select
      hist.project_id,
      p.name as project_name,
      count(*)::int as supporting_spans,
      max(hist.attribution_ts_utc) as last_seen_at_utc
    from (
      select
        i2.interaction_id,
        coalesce(sa2.applied_project_id, sa2.project_id) as project_id,
        coalesce(sa2.applied_at_utc, sa2.attributed_at, cs2.created_at) as attribution_ts_utc
      from public.interactions i2
      join public.conversation_spans cs2
        on cs2.interaction_id = i2.interaction_id
       and cs2.is_superseded = false
      join public.span_attributions sa2
        on sa2.span_id = cs2.id
      where coalesce(sa2.applied_project_id, sa2.project_id) is not null
        and i2.interaction_id <> s.interaction_id
        and (
          (s.contact_id is not null and i2.contact_id = s.contact_id)
          or (
            s.contact_id is null
            and s.contact_phone_digits <> ''
            and regexp_replace(coalesce(i2.contact_phone, ''), '\D', '', 'g') = s.contact_phone_digits
          )
        )
    ) hist
    join public.projects p
      on p.id = hist.project_id
    where hist.project_id is distinct from s.attributed_project_id
    group by hist.project_id, p.name
    order by supporting_spans desc, last_seen_at_utc desc nulls last
    limit 5
  ) ranked
) fc on true
order by s.call_time_utc desc, s.interaction_id, s.span_index;
