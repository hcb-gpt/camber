-- Standing audit loop sampler + recorder for production attribution integrity.
-- Creates/updates one eval run per UTC day and inserts:
--   - 10 daily random spans (last 24h)
--   - 5 high-risk spans (low confidence / weak evidence / floater contacts)
--   - 5 conflict-signal spans (last 30d where claim pointers disagree with assigned project)
--
-- Run:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   scripts/query.sh --file scripts/sql/prod_attrib_audit_sampler_and_recorder.sql

with settings as (
  select
    (now() at time zone 'utc')::date as run_date_utc,
    'prod_attrib_audit_' || to_char((now() at time zone 'utc')::date, 'YYYYMMDD') as run_name,
    10::int as daily_random_n,
    5::int as high_risk_n,
    5::int as conflict_n,
    30::int as conflict_window_days,
    abs(hashtext(to_char((now() at time zone 'utc')::date, 'YYYYMMDD') || ':prod_attrib_audit')::bigint) as rng_seed
),
latest_attribution as (
  select distinct on (sa.span_id)
    sa.id as attribution_id,
    sa.span_id,
    coalesce(sa.applied_project_id, sa.project_id) as assigned_project_id,
    sa.confidence,
    sa.decision,
    sa.evidence_tier,
    sa.attributed_at
  from public.span_attributions sa
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
span_population as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.segment_generation as generation,
    cs.span_index,
    cs.char_start,
    cs.char_end,
    cs.transcript_segment,
    coalesce(i.event_at_utc, i.ingested_at_utc, cs.created_at) as call_at_utc,
    la.assigned_project_id,
    la.confidence,
    la.evidence_tier,
    coalesce(c.floats_between_projects, false) as floats_between_projects
  from public.conversation_spans cs
  join latest_attribution la on la.span_id = cs.id
  join public.interactions i on i.interaction_id = cs.interaction_id
  left join public.contacts c on c.id = i.contact_id
  where cs.is_superseded = false
    and la.decision = 'assign'
    and la.assigned_project_id is not null
),
population as (
  select *
  from span_population sp
  where sp.call_at_utc >= (now() - interval '24 hours')
),
conflict_population as (
  select
    sp.span_id,
    sp.interaction_id,
    sp.generation,
    sp.span_index,
    sp.char_start,
    sp.char_end,
    sp.transcript_segment,
    sp.call_at_utc,
    sp.assigned_project_id,
    sp.confidence,
    sp.evidence_tier,
    sp.floats_between_projects,
    count(cp.id)::int as disagree_pointer_count,
    md5((select s.rng_seed::text from settings s) || ':conflict:' || sp.span_id::text) as order_hash
  from span_population sp
  join public.claim_pointers cp
    on cp.source_id = sp.interaction_id
   and (
     cp.char_start is null
     or cp.char_end is null
     or (cp.char_start < sp.char_end and cp.char_end > sp.char_start)
   )
  join public.belief_claims bc
    on bc.id = cp.claim_id
   and bc.project_id <> sp.assigned_project_id
  where sp.call_at_utc >= (now() - ((select conflict_window_days from settings)::text || ' days')::interval)
  group by
    sp.span_id,
    sp.interaction_id,
    sp.generation,
    sp.span_index,
    sp.char_start,
    sp.char_end,
    sp.transcript_segment,
    sp.call_at_utc,
    sp.assigned_project_id,
    sp.confidence,
    sp.evidence_tier,
    sp.floats_between_projects
),
daily_sample as (
  select
    p.*,
    md5((select s.rng_seed::text from settings s) || ':daily:' || p.span_id::text) as order_hash
  from population p
  order by order_hash
  limit (select daily_random_n from settings)
),
high_risk_population as (
  select
    p.*,
    case when p.confidence is not null and p.confidence < 0.70 then 1 else 0 end as low_conf_flag,
    case when p.evidence_tier is null or p.evidence_tier >= 3 then 1 else 0 end as weak_evidence_flag,
    case when p.floats_between_projects then 1 else 0 end as floater_flag
  from population p
  where
    (p.confidence is not null and p.confidence < 0.70)
    or p.evidence_tier is null
    or p.evidence_tier >= 3
    or p.floats_between_projects
),
high_risk_sample as (
  select
    hr.*,
    (hr.low_conf_flag + hr.weak_evidence_flag + hr.floater_flag)::numeric as risk_weight,
    md5((select s.rng_seed::text from settings s) || ':risk:' || hr.span_id::text) as order_hash
  from high_risk_population hr
  where not exists (
    select 1
    from daily_sample ds
    where ds.span_id = hr.span_id
  )
  order by order_hash
  limit (select high_risk_n from settings)
),
conflict_sample as (
  select
    cp.*,
    greatest(cp.disagree_pointer_count, 1)::numeric as conflict_weight
  from conflict_population cp
  where not exists (
    select 1 from daily_sample ds where ds.span_id = cp.span_id
  )
    and not exists (
      select 1 from high_risk_sample hrs where hrs.span_id = cp.span_id
    )
  order by cp.order_hash
  limit (select conflict_n from settings)
),
selected as (
  select
    'daily_random'::text as sampling_reason,
    1::int as cohort_order,
    ds.span_id,
    ds.interaction_id,
    ds.generation,
    null::numeric as sampling_weight,
    ds.order_hash
  from daily_sample ds

  union all

  select
    'high_risk'::text as sampling_reason,
    2::int as cohort_order,
    hrs.span_id,
    hrs.interaction_id,
    hrs.generation,
    coalesce(hrs.risk_weight, 1)::numeric as sampling_weight,
    hrs.order_hash
  from high_risk_sample hrs

  union all

  select
    'conflict_signal'::text as sampling_reason,
    3::int as cohort_order,
    cs.span_id,
    cs.interaction_id,
    cs.generation,
    cs.conflict_weight as sampling_weight,
    cs.order_hash
  from conflict_sample cs
),
run_upsert as (
  insert into public.eval_runs (
    created_by,
    name,
    description,
    population_query,
    population_params,
    sampling_strategy,
    sampling_params,
    replay_flags,
    proof_required,
    status,
    client_request_id
  )
  select
    'data-2'::text as created_by,
    s.run_name,
    'Production attribution integrity audit: daily random + high-risk + conflict-signal spans'::text,
    'conversation_spans + span_attributions(assign, non-null project) from last 24h plus conflict-signal spans from last 30d'::text,
    jsonb_build_object(
      'window_hours', 24,
      'decision', 'assign',
      'project_required', true,
      'conflict_window_days', s.conflict_window_days
    ),
    'stratified'::text,
    jsonb_build_object(
      'daily_random_n', s.daily_random_n,
      'high_risk_n', s.high_risk_n,
      'conflict_n', s.conflict_n,
      'rng_seed', s.rng_seed
    ),
    jsonb_build_object(
      'review_mode', 'external_reviewer',
      'no_future_leakage', true
    ),
    true,
    'queued'::text,
    'prod_attrib_audit:' || s.run_name || ':seed:' || s.rng_seed::text
  from settings s
  on conflict (client_request_id) do update
    set description = excluded.description,
        population_query = excluded.population_query,
        population_params = excluded.population_params,
        sampling_strategy = excluded.sampling_strategy,
        sampling_params = excluded.sampling_params,
        replay_flags = excluded.replay_flags,
        proof_required = excluded.proof_required
  returning id, name
),
sample_insert as (
  insert into public.eval_samples (
    eval_run_id,
    interaction_id,
    generation,
    span_id,
    sample_rank,
    sampling_weight,
    sampling_reason,
    status,
    client_request_id
  )
  select
    ru.id as eval_run_id,
    sel.interaction_id,
    sel.generation,
    sel.span_id,
    row_number() over (
      order by sel.cohort_order, sel.order_hash, sel.span_id
    )::int as sample_rank,
    sel.sampling_weight,
    sel.sampling_reason,
    'queued'::text as status,
    'prod_attrib_audit:' || ru.name || ':span:' || sel.span_id::text as client_request_id
  from selected sel
  cross join run_upsert ru
  on conflict (client_request_id) do nothing
  returning eval_run_id, sampling_reason
),
run_stats as (
  select
    ru.id as eval_run_id,
    ru.name as eval_run_name,
    coalesce(er.status, 'queued') as eval_run_status,
    (
      select count(*)::int
      from public.eval_samples es
      where es.eval_run_id = ru.id
    ) as total_samples
  from run_upsert ru
  left join public.eval_runs er on er.id = ru.id
)
select
  rs.eval_run_id,
  rs.eval_run_name,
  rs.eval_run_status,
  rs.total_samples,
  coalesce((select count(*) from sample_insert where sampling_reason = 'daily_random'), 0) as inserted_daily_random,
  coalesce((select count(*) from sample_insert where sampling_reason = 'high_risk'), 0) as inserted_high_risk,
  coalesce((select count(*) from sample_insert where sampling_reason = 'conflict_signal'), 0) as inserted_conflict_signal,
  (select rng_seed from settings) as rng_seed
from run_stats rs;

with settings as (
  select
    'prod_attrib_audit_' || to_char((now() at time zone 'utc')::date, 'YYYYMMDD') as run_name,
    abs(hashtext(to_char((now() at time zone 'utc')::date, 'YYYYMMDD') || ':prod_attrib_audit')::bigint) as rng_seed
),
target_run as (
  select er.id, er.name
  from public.eval_runs er
  join settings s
    on er.client_request_id = 'prod_attrib_audit:' || s.run_name || ':seed:' || s.rng_seed::text
  limit 1
)
select
  tr.id as eval_run_id,
  tr.name as eval_run_name,
  es.sample_rank,
  es.sampling_reason,
  es.interaction_id,
  es.span_id,
  es.status
from target_run tr
join public.eval_samples es on es.eval_run_id = tr.id
order by es.sample_rank;
