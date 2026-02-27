begin;

create or replace view public.v_beside_shadow_metrics_packet_v0 as
with params as (
  select
    now() as as_of_utc,
    now() - interval '72 hours' as window_72h_start_utc,
    now() - interval '7 days' as window_7d_start_utc,
    now() - interval '30 minutes' as freshness_cutoff_utc,
    60::int as occurred_at_tolerance_seconds,
    30::int as freshness_exclusion_minutes
),
match_rollup as (
  select
    p.as_of_utc,
    p.window_72h_start_utc as window_start_utc,
    p.as_of_utc as window_end_utc,
    coalesce(sum(v.compared_pairs), 0)::bigint as compared_pairs,
    coalesce(sum(v.full_match_pairs), 0)::bigint as full_match_pairs,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum(v.full_match_pairs)::numeric / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as match_rate,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum((v.contact_match_rate * v.compared_pairs)::numeric) / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as contact_match_rate,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum((v.project_match_rate * v.compared_pairs)::numeric) / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as project_match_rate,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum((v.interaction_type_match_rate * v.compared_pairs)::numeric) / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as interaction_type_match_rate,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum((v.occurred_at_match_rate * v.compared_pairs)::numeric) / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as occurred_at_match_rate,
    case
      when coalesce(sum(v.compared_pairs), 0) = 0 then 0::numeric(6, 4)
      else round(sum((v.body_hash_match_rate * v.compared_pairs)::numeric) / sum(v.compared_pairs)::numeric, 4)::numeric(6, 4)
    end as body_hash_match_rate,
    p.occurred_at_tolerance_seconds
  from params p
  left join public.v_beside_direct_read_parity_72h v on true
  group by
    p.as_of_utc,
    p.window_72h_start_utc,
    p.occurred_at_tolerance_seconds
),
eligible_7d as (
  select distinct e.camber_interaction_id as interaction_id
  from public.beside_thread_events e
  cross join params p
  where e.source = 'beside_direct_read'
    and coalesce(e.camber_interaction_id, '') <> ''
    and e.captured_at_utc >= p.window_7d_start_utc
    and e.captured_at_utc < p.freshness_cutoff_utc
),
pipeline_completed as (
  select e.interaction_id
  from eligible_7d e
  where exists (
    select 1
    from public.conversation_spans s
    where s.interaction_id = e.interaction_id
      and s.is_superseded = false
  )
),
orphan_eval as (
  select
    pc.interaction_id,
    coalesce(i.project_id, vip.primary_project_id) as project_id
  from pipeline_completed pc
  left join public.interactions i
    on i.interaction_id = pc.interaction_id
  left join public.v_interaction_primary_project vip
    on vip.interaction_id = pc.interaction_id
),
orphan_rollup as (
  select
    p.as_of_utc,
    p.window_7d_start_utc as window_start_utc,
    p.as_of_utc as window_end_utc,
    (select count(*) from eligible_7d)::bigint as eligible_interactions,
    (select count(*) from orphan_eval)::bigint as pipeline_completed_interactions,
    (select count(*) from orphan_eval where project_id is null)::bigint as orphan_interactions,
    case
      when (select count(*) from eligible_7d) = 0 then 0::numeric(6, 4)
      else round(
        (select count(*) from orphan_eval where project_id is null)::numeric
        / (select count(*) from eligible_7d)::numeric,
        4
      )::numeric(6, 4)
    end as orphan_rate,
    p.freshness_exclusion_minutes
  from params p
),
watcher_samples as (
  select
    greatest(
      extract(
        epoch from (
          coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) - e.captured_at_utc
        )
      ) * 1000.0,
      0
    ) as latency_ms
  from public.beside_thread_events e
  join public.calls_raw cr
    on cr.interaction_id = e.camber_interaction_id
  cross join params p
  where e.source = 'beside_direct_read'
    and e.captured_at_utc >= p.window_72h_start_utc
    and e.captured_at_utc < p.freshness_cutoff_utc
    and coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) >= e.captured_at_utc
),
ingest_samples as (
  select
    greatest(
      extract(epoch from (max(s.created_at) - e.captured_at_utc)) * 1000.0,
      0
    ) as latency_ms
  from public.beside_thread_events e
  join public.conversation_spans s
    on s.interaction_id = e.camber_interaction_id
   and s.is_superseded = false
  cross join params p
  where e.source = 'beside_direct_read'
    and e.captured_at_utc >= p.window_72h_start_utc
    and e.captured_at_utc < p.freshness_cutoff_utc
  group by e.beside_event_id, e.captured_at_utc
  having max(s.created_at) >= e.captured_at_utc
),
latency_rollup as (
  select
    'watcher_to_calls_raw'::text as path,
    p.as_of_utc,
    (select count(*) from watcher_samples)::bigint as sample_count,
    (select percentile_cont(0.50) within group (order by ws.latency_ms) from watcher_samples ws) as p50_ms,
    (select percentile_cont(0.95) within group (order by ws.latency_ms) from watcher_samples ws) as p95_ms,
    (select percentile_cont(0.99) within group (order by ws.latency_ms) from watcher_samples ws) as p99_ms,
    60000::int as slo_ms,
    case
      when (select count(*) from watcher_samples) = 0 then 0::numeric(6, 4)
      else round((select avg((ws.latency_ms <= 60000)::int)::numeric from watcher_samples ws), 4)::numeric(6, 4)
    end as within_slo_rate
  from params p

  union all

  select
    'cache_to_spans_completed'::text as path,
    p.as_of_utc,
    (select count(*) from ingest_samples)::bigint as sample_count,
    (select percentile_cont(0.50) within group (order by isamp.latency_ms) from ingest_samples isamp) as p50_ms,
    (select percentile_cont(0.95) within group (order by isamp.latency_ms) from ingest_samples isamp) as p95_ms,
    (select percentile_cont(0.99) within group (order by isamp.latency_ms) from ingest_samples isamp) as p99_ms,
    120000::int as slo_ms,
    case
      when (select count(*) from ingest_samples) = 0 then 0::numeric(6, 4)
      else round((select avg((isamp.latency_ms <= 120000)::int)::numeric from ingest_samples isamp), 4)::numeric(6, 4)
    end as within_slo_rate
  from params p
),
packet as (
  select
    1 as ord,
    'match_rate_72h'::text as section,
    jsonb_build_object(
      'as_of_utc', m.as_of_utc,
      'window_start_utc', m.window_start_utc,
      'window_end_utc', m.window_end_utc,
      'compared_pairs', m.compared_pairs,
      'full_match_pairs', m.full_match_pairs,
      'match_rate', m.match_rate,
      'contact_match_rate', m.contact_match_rate,
      'project_match_rate', m.project_match_rate,
      'interaction_type_match_rate', m.interaction_type_match_rate,
      'occurred_at_match_rate', m.occurred_at_match_rate,
      'body_hash_match_rate', m.body_hash_match_rate,
      'occurred_at_tolerance_seconds', m.occurred_at_tolerance_seconds
    ) as payload
  from match_rollup m

  union all

  select
    2 as ord,
    'orphan_rate_7d'::text as section,
    jsonb_build_object(
      'as_of_utc', o.as_of_utc,
      'window_start_utc', o.window_start_utc,
      'window_end_utc', o.window_end_utc,
      'eligible_interactions', o.eligible_interactions,
      'pipeline_completed_interactions', o.pipeline_completed_interactions,
      'orphan_interactions', o.orphan_interactions,
      'orphan_rate', o.orphan_rate,
      'freshness_exclusion_minutes', o.freshness_exclusion_minutes
    ) as payload
  from orphan_rollup o

  union all

  select
    3 as ord,
    'latency_slo'::text as section,
    jsonb_build_object(
      'path', l.path,
      'as_of_utc', l.as_of_utc,
      'sample_count', l.sample_count,
      'p50_ms', l.p50_ms,
      'p95_ms', l.p95_ms,
      'p99_ms', l.p99_ms,
      'slo_ms', l.slo_ms,
      'within_slo_rate', l.within_slo_rate
    ) as payload
  from latency_rollup l
)
select section, payload
from packet
order by ord, section;

comment on view public.v_beside_shadow_metrics_packet_v0 is
  'Beside shadow packet v0: match_rate_72h, orphan_rate_7d, and latency_slo JSON payloads (occurred_at tolerance=60s, freshness exclusion=30m).';

grant select on public.v_beside_shadow_metrics_packet_v0 to anon, authenticated, service_role;

commit;
