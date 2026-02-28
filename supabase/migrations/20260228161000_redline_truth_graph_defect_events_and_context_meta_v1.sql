-- P0: Redline truth-forcing substrate
-- Receipt: p0_redline_truth_graph_defect_events_and_materialized_context__20260228

begin;

create table if not exists public.redline_defect_events (
  defect_event_id uuid primary key default gen_random_uuid(),
  defect_type text not null check (
    defect_type in (
      'ingestion_missing',
      'projection_gap',
      'missing_evidence',
      'missing_attribution',
      'stale_context',
      'sms_gap',
      'journal_gap',
      'other'
    )
  ),
  owner_lane text not null check (
    owner_lane in ('ingestion', 'segmentation', 'attribution', 'journal', 'projection', 'client')
  ),
  interaction_id text,
  interaction_uuid uuid,
  thread_id text,
  span_id uuid,
  evidence_event_id uuid,
  project_id uuid,
  first_seen_at_utc timestamptz not null default now(),
  last_seen_at_utc timestamptz not null default now(),
  current_status text not null default 'open' check (current_status in ('open', 'closed')),
  closure_proof jsonb,
  details jsonb not null default '{}'::jsonb,
  dedupe_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (dedupe_key)
);

alter table public.redline_defect_events
  add column if not exists interaction_uuid uuid;

alter table public.redline_defect_events
  add column if not exists details jsonb;

alter table public.redline_defect_events
  add column if not exists dedupe_key text;

alter table public.redline_defect_events
  add column if not exists closure_proof jsonb;

update public.redline_defect_events rde
set details = '{}'::jsonb
where rde.details is null;

update public.redline_defect_events rde
set closure_proof = '{}'::jsonb
where rde.closure_proof is null;

update public.redline_defect_events rde
set dedupe_key = md5(concat_ws(
  '|',
  coalesce(rde.defect_type, ''),
  coalesce(rde.owner_lane, ''),
  coalesce(rde.interaction_id, ''),
  coalesce(rde.thread_id, ''),
  coalesce(rde.span_id::text, ''),
  coalesce(rde.evidence_event_id::text, ''),
  coalesce(rde.project_id::text, ''),
  coalesce(rde.defect_event_id::text, '')
))
where rde.dedupe_key is null;

alter table public.redline_defect_events
  alter column details set default '{}'::jsonb;

alter table public.redline_defect_events
  alter column closure_proof set default '{}'::jsonb;

alter table public.redline_defect_events
  alter column details set not null;

alter table public.redline_defect_events
  alter column dedupe_key set not null;

create unique index if not exists idx_redline_defect_events_dedupe_key
  on public.redline_defect_events(dedupe_key);

create index if not exists idx_redline_defect_events_status_seen
  on public.redline_defect_events(current_status, last_seen_at_utc desc);

create index if not exists idx_redline_defect_events_interaction
  on public.redline_defect_events(interaction_id, current_status, last_seen_at_utc desc);

create or replace function public.trg_redline_defect_events_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_redline_defect_events_touch_updated_at on public.redline_defect_events;
create trigger trg_redline_defect_events_touch_updated_at
before update on public.redline_defect_events
for each row
execute function public.trg_redline_defect_events_touch_updated_at();

create or replace view public.v_redline_defect_events_open as
select
  rde.defect_event_id,
  rde.defect_type,
  rde.owner_lane,
  rde.interaction_id,
  rde.interaction_uuid,
  rde.thread_id,
  rde.span_id,
  rde.evidence_event_id,
  rde.project_id,
  rde.first_seen_at_utc,
  rde.last_seen_at_utc,
  extract(epoch from (now() - rde.first_seen_at_utc))::bigint as age_seconds,
  rde.details
from public.redline_defect_events rde
where rde.current_status = 'open'
order by rde.last_seen_at_utc desc;

comment on table public.redline_defect_events is
'SSOT defect log for Redline truth forcing. Tracks root-cause defect events with lane ownership and closure proof pointers.';

comment on view public.v_redline_defect_events_open is
'Open Redline defect events ordered by recency with age_seconds for SLA monitoring.';

create table if not exists public.project_context_materialization_meta (
  meta_id uuid primary key default gen_random_uuid(),
  context_version text not null,
  refreshed_at_utc timestamptz not null,
  source_views text[] not null,
  pipeline_run_id text,
  activity_anchor_source text,
  activity_anchor_at_utc timestamptz,
  staleness_status_at_refresh text not null check (
    staleness_status_at_refresh in ('fresh', 'lagging', 'stale', 'unknown')
  ),
  refresh_status text not null default 'success' check (
    refresh_status in ('success', 'failed', 'running')
  ),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_project_context_materialization_meta_refreshed
  on public.project_context_materialization_meta(refreshed_at_utc desc);

comment on table public.project_context_materialization_meta is
'Companion metadata for mat_project_context refreshes. Anchors freshness to successful pipeline activity.';

create or replace function public.compute_project_context_staleness_status_v1(
  p_refreshed_at_utc timestamptz,
  p_activity_anchor_at_utc timestamptz,
  p_allowed_lag interval default interval '15 minutes'
)
returns text
language sql
immutable
as $$
  select case
    when p_activity_anchor_at_utc is null then 'unknown'
    when p_refreshed_at_utc is null then 'stale'
    when p_refreshed_at_utc >= p_activity_anchor_at_utc then 'fresh'
    when p_refreshed_at_utc >= p_activity_anchor_at_utc - p_allowed_lag then 'lagging'
    else 'stale'
  end;
$$;

create or replace function public.get_latest_pipeline_activity_success_v1()
returns table (
  activity_source text,
  activity_at_utc timestamptz,
  pipeline_run_id text
)
language sql
stable
as $$
  with activity as (
    select
      'journal_runs'::text as activity_source,
      jr.completed_at as activity_at_utc,
      jr.run_id::text as pipeline_run_id
    from public.journal_runs jr
    where jr.status = 'success'
      and jr.completed_at is not null

    union all

    select
      ('pipedream_run_logs:' || coalesce(prl.stage, 'unknown'))::text as activity_source,
      prl.created_at as activity_at_utc,
      coalesce(prl.meta->>'run_id', prl.id::text) as pipeline_run_id
    from public.pipedream_run_logs prl
    where prl.ok is true
  )
  select
    activity_source,
    activity_at_utc,
    pipeline_run_id
  from activity
  order by activity_at_utc desc nulls last
  limit 1;
$$;

create or replace function public.record_project_context_materialization_refresh_v1(
  p_pipeline_run_id text default null,
  p_context_version text default 'v1',
  p_source_views text[] default array['v_project_feed'],
  p_refresh_status text default 'success',
  p_notes text default null
)
returns table (
  meta_id uuid,
  refreshed_at_utc timestamptz,
  activity_anchor_at_utc timestamptz,
  staleness_status_at_refresh text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_activity_source text;
  v_activity_at timestamptz;
  v_activity_run_id text;
  v_refreshed_at timestamptz := now();
  v_staleness text;
begin
  select
    a.activity_source,
    a.activity_at_utc,
    a.pipeline_run_id
  into v_activity_source, v_activity_at, v_activity_run_id
  from public.get_latest_pipeline_activity_success_v1() a;

  v_staleness := public.compute_project_context_staleness_status_v1(v_refreshed_at, v_activity_at);

  return query
  insert into public.project_context_materialization_meta (
    context_version,
    refreshed_at_utc,
    source_views,
    pipeline_run_id,
    activity_anchor_source,
    activity_anchor_at_utc,
    staleness_status_at_refresh,
    refresh_status,
    notes
  )
  values (
    coalesce(nullif(trim(p_context_version), ''), 'v1'),
    v_refreshed_at,
    coalesce(p_source_views, array['v_project_feed']),
    coalesce(nullif(trim(p_pipeline_run_id), ''), v_activity_run_id),
    v_activity_source,
    v_activity_at,
    v_staleness,
    case
      when p_refresh_status in ('success', 'failed', 'running') then p_refresh_status
      else 'success'
    end,
    p_notes
  )
  returning
    project_context_materialization_meta.meta_id,
    project_context_materialization_meta.refreshed_at_utc,
    project_context_materialization_meta.activity_anchor_at_utc,
    project_context_materialization_meta.staleness_status_at_refresh;
end;
$$;

create or replace view public.v_project_context_materialization_health_v1 as
with latest_meta as (
  select
    pcm.meta_id,
    pcm.context_version,
    pcm.refreshed_at_utc,
    pcm.source_views,
    pcm.pipeline_run_id,
    pcm.activity_anchor_source,
    pcm.activity_anchor_at_utc,
    pcm.staleness_status_at_refresh,
    pcm.refresh_status,
    pcm.notes,
    pcm.created_at
  from public.project_context_materialization_meta pcm
  order by pcm.refreshed_at_utc desc, pcm.created_at desc
  limit 1
), latest_activity as (
  select
    a.activity_source,
    a.activity_at_utc,
    a.pipeline_run_id as activity_pipeline_run_id
  from public.get_latest_pipeline_activity_success_v1() a
)
select
  lm.meta_id,
  lm.context_version,
  lm.refreshed_at_utc,
  lm.source_views,
  lm.pipeline_run_id,
  lm.activity_anchor_source,
  lm.activity_anchor_at_utc,
  la.activity_source as latest_pipeline_activity_source,
  la.activity_at_utc as latest_pipeline_activity_at_utc,
  la.activity_pipeline_run_id,
  public.compute_project_context_staleness_status_v1(lm.refreshed_at_utc, la.activity_at_utc) as staleness_status,
  case
    when la.activity_at_utc is null then null::integer
    else greatest(0, extract(epoch from (la.activity_at_utc - lm.refreshed_at_utc))::integer)
  end as lag_seconds,
  lm.staleness_status_at_refresh,
  lm.refresh_status,
  lm.notes,
  lm.created_at
from latest_meta lm
left join latest_activity la on true;

create or replace view public.v_mat_project_context_with_meta_v1 as
select
  mpc.*,
  pcmh.context_version,
  pcmh.refreshed_at_utc as context_refreshed_at_utc,
  pcmh.source_views as context_source_views,
  pcmh.pipeline_run_id as context_pipeline_run_id,
  pcmh.staleness_status as context_staleness_status,
  pcmh.latest_pipeline_activity_at_utc,
  pcmh.latest_pipeline_activity_source,
  pcmh.lag_seconds as context_lag_seconds
from public.mat_project_context mpc
cross join public.v_project_context_materialization_health_v1 pcmh;

comment on view public.v_project_context_materialization_health_v1 is
'Staleness rule anchored to latest successful pipeline activity. stale/lagging/fresh classification for mat_project_context metadata.';

comment on view public.v_mat_project_context_with_meta_v1 is
'Fast read surface for Redline/Claude: mat_project_context rows with materialization metadata and staleness status.';

create or replace function public.record_redline_defect_event_v1(
  p_defect_type text,
  p_owner_lane text,
  p_interaction_id text default null,
  p_thread_id text default null,
  p_span_id uuid default null,
  p_evidence_event_id uuid default null,
  p_project_id uuid default null,
  p_details jsonb default '{}'::jsonb,
  p_closure_proof jsonb default null,
  p_current_status text default 'open'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_defect_event_id uuid;
  v_interaction_uuid uuid;
  v_thread_id text := p_thread_id;
  v_project_id uuid := p_project_id;
  v_status text := case when p_current_status in ('open', 'closed') then p_current_status else 'open' end;
  v_dedupe_key text;
begin
  if p_owner_lane not in ('ingestion', 'segmentation', 'attribution', 'journal', 'projection', 'client') then
    raise exception 'invalid_owner_lane: %', p_owner_lane;
  end if;

  if p_defect_type not in (
    'ingestion_missing', 'projection_gap', 'missing_evidence', 'missing_attribution', 'stale_context', 'sms_gap',
    'journal_gap', 'other'
  ) then
    raise exception 'invalid_defect_type: %', p_defect_type;
  end if;

  if coalesce(nullif(trim(coalesce(p_interaction_id, '')), ''), '') <> '' then
    select
      i.id,
      i.thread_key,
      i.project_id
    into v_interaction_uuid, v_thread_id, v_project_id
    from public.interactions i
    where i.interaction_id = p_interaction_id
    order by i.ingested_at_utc desc nulls last
    limit 1;

    if p_thread_id is not null then
      v_thread_id := p_thread_id;
    end if;

    if p_project_id is not null then
      v_project_id := p_project_id;
    end if;
  end if;

  v_dedupe_key := md5(concat_ws(
    '|',
    p_defect_type,
    coalesce(p_owner_lane, ''),
    coalesce(p_interaction_id, ''),
    coalesce(v_thread_id, ''),
    coalesce(p_span_id::text, ''),
    coalesce(p_evidence_event_id::text, ''),
    coalesce(v_project_id::text, '')
  ));

  insert into public.redline_defect_events (
    defect_type,
    owner_lane,
    interaction_id,
    interaction_uuid,
    thread_id,
    span_id,
    evidence_event_id,
    project_id,
    first_seen_at_utc,
    last_seen_at_utc,
    current_status,
    closure_proof,
    details,
    dedupe_key
  )
  values (
    p_defect_type,
    p_owner_lane,
    p_interaction_id,
    v_interaction_uuid,
    v_thread_id,
    p_span_id,
    p_evidence_event_id,
    v_project_id,
    now(),
    now(),
    v_status,
    coalesce(p_closure_proof, '{}'::jsonb),
    coalesce(p_details, '{}'::jsonb),
    v_dedupe_key
  )
  on conflict (dedupe_key)
  do update set
    last_seen_at_utc = now(),
    current_status = excluded.current_status,
    closure_proof = coalesce(excluded.closure_proof, public.redline_defect_events.closure_proof, '{}'::jsonb),
    details = coalesce(public.redline_defect_events.details, '{}'::jsonb) || coalesce(excluded.details, '{}'::jsonb),
    interaction_uuid = coalesce(public.redline_defect_events.interaction_uuid, excluded.interaction_uuid),
    thread_id = coalesce(public.redline_defect_events.thread_id, excluded.thread_id),
    project_id = coalesce(public.redline_defect_events.project_id, excluded.project_id),
    updated_at = now()
  returning public.redline_defect_events.defect_event_id
  into v_defect_event_id;

  return v_defect_event_id;
end;
$$;

drop function if exists public.redline_truth_graph_v1(text);

create or replace function public.redline_truth_graph_v1(p_interaction_id text)
returns table (
  interaction_id text,
  interaction_uuid uuid,
  project_id uuid,
  thread_id text,
  lane_label text,
  primary_defect_type text,
  node_statuses jsonb,
  calls_raw_ids uuid[],
  interaction_ids text[],
  span_ids uuid[],
  evidence_event_ids uuid[],
  span_attribution_ids uuid[],
  review_queue_ids uuid[],
  journal_claim_ids uuid[],
  journal_open_loop_ids uuid[],
  redline_thread_rows integer,
  context_staleness_status text,
  context_refreshed_at_utc timestamptz,
  latest_pipeline_activity_at_utc timestamptz
)
language sql
stable
as $$
with i as (
  select
    i.id,
    i.interaction_id,
    i.project_id,
    i.thread_key,
    i.event_at_utc,
    i.ingested_at_utc
  from public.interactions i
  where i.interaction_id = p_interaction_id
), i_latest as (
  select
    i.id,
    i.interaction_id,
    i.project_id,
    i.thread_key
  from i
  order by i.ingested_at_utc desc nulls last, i.event_at_utc desc nulls last
  limit 1
), calls as (
  select
    count(*)::int as cnt,
    coalesce(array_agg(cr.id order by cr.event_at_utc desc), array[]::uuid[]) as ids
  from public.calls_raw cr
  where cr.interaction_id = p_interaction_id
    and coalesce(cr.is_shadow, false) = false
), spans as (
  select
    count(*)::int as cnt,
    coalesce(array_agg(cs.id order by cs.span_index), array[]::uuid[]) as ids
  from public.conversation_spans cs
  where cs.interaction_id = p_interaction_id
    and coalesce(cs.is_superseded, false) = false
), evidence as (
  select
    count(*)::int as cnt,
    coalesce(array_agg(ev.evidence_event_id order by ev.created_at desc), array[]::uuid[]) as ids
  from public.evidence_events ev
  where ev.source_id = p_interaction_id
     or coalesce(ev.metadata->>'interaction_id', '') = p_interaction_id
     or coalesce(ev.metadata->>'call_id', '') = p_interaction_id
), attrs as (
  select
    count(*)::int as cnt,
    count(*) filter (where coalesce(sa.needs_review, false) is true)::int as needs_review_cnt,
    coalesce(array_agg(sa.id order by sa.attributed_at desc), array[]::uuid[]) as ids
  from public.span_attributions sa
  join public.conversation_spans cs on cs.id = sa.span_id
  where cs.interaction_id = p_interaction_id
    and coalesce(cs.is_superseded, false) = false
), rq as (
  select
    count(*)::int as cnt,
    count(*) filter (where rq.status = 'pending')::int as pending_cnt,
    coalesce(array_agg(rq.id order by rq.created_at desc), array[]::uuid[]) as ids
  from public.review_queue rq
  where rq.interaction_id = p_interaction_id
     or rq.span_id in (
        select cs.id
        from public.conversation_spans cs
        where cs.interaction_id = p_interaction_id
          and coalesce(cs.is_superseded, false) = false
     )
), jc as (
  select
    count(*)::int as cnt,
    count(*) filter (where coalesce(jc.active, false) is true)::int as active_cnt,
    coalesce(array_agg(jc.id order by jc.created_at desc), array[]::uuid[]) as ids
  from public.journal_claims jc
  where jc.call_id = p_interaction_id
), jol as (
  select
    count(*)::int as cnt,
    count(*) filter (where jol.status = 'open')::int as open_cnt,
    coalesce(array_agg(jol.id order by jol.created_at desc), array[]::uuid[]) as ids
  from public.journal_open_loops jol
  where jol.call_id = p_interaction_id
), rt as (
  select
    count(*)::int as cnt
  from public.redline_thread rt
  where rt.interaction_id in (
    select i2.id from i i2
  )
), meta as (
  select
    coalesce(vpcmh.staleness_status, 'unknown') as staleness_status,
    vpcmh.refreshed_at_utc,
    vpcmh.latest_pipeline_activity_at_utc
  from public.v_project_context_materialization_health_v1 vpcmh
)
select
  p_interaction_id as interaction_id,
  il.id as interaction_uuid,
  il.project_id,
  il.thread_key as thread_id,
  case
    when calls.cnt = 0 or (select count(*) from i) = 0 then 'ingestion'
    when spans.cnt = 0 then 'segmentation'
    when evidence.cnt = 0 then 'segmentation'
    when attrs.cnt = 0 then 'attribution'
    when rt.cnt = 0 then 'projection'
    when meta.staleness_status = 'stale' then 'projection'
    when rq.pending_cnt > 0 then 'client'
    when jc.active_cnt = 0 and jol.open_cnt = 0 then 'journal'
    else 'healthy'
  end as lane_label,
  case
    when calls.cnt = 0 or (select count(*) from i) = 0 then 'ingestion_missing'
    when spans.cnt = 0 then 'missing_evidence'
    when evidence.cnt = 0 then 'missing_evidence'
    when attrs.cnt = 0 then 'missing_attribution'
    when rt.cnt = 0 then 'projection_gap'
    when meta.staleness_status = 'stale' then 'stale_context'
    when rq.pending_cnt > 0 then 'missing_attribution'
    when jc.active_cnt = 0 and jol.open_cnt = 0 then 'journal_gap'
    else null
  end as primary_defect_type,
  jsonb_build_object(
    'calls_raw', jsonb_build_object('present', calls.cnt > 0, 'count', calls.cnt, 'ids', to_jsonb(calls.ids)),
    'interactions', jsonb_build_object(
      'present', (select count(*) from i) > 0,
      'count', (select count(*) from i),
      'ids', to_jsonb(coalesce((select array_agg(i2.interaction_id order by i2.ingested_at_utc desc) from i i2), array[]::text[]))
    ),
    'conversation_spans', jsonb_build_object('present', spans.cnt > 0, 'count', spans.cnt, 'ids', to_jsonb(spans.ids)),
    'evidence_events', jsonb_build_object('present', evidence.cnt > 0, 'count', evidence.cnt, 'ids', to_jsonb(evidence.ids)),
    'span_attributions', jsonb_build_object('present', attrs.cnt > 0, 'count', attrs.cnt, 'needs_review_count', attrs.needs_review_cnt, 'ids', to_jsonb(attrs.ids)),
    'review_queue', jsonb_build_object('present', rq.cnt > 0, 'count', rq.cnt, 'pending_count', rq.pending_cnt, 'ids', to_jsonb(rq.ids)),
    'journal_claims', jsonb_build_object('present', jc.cnt > 0, 'count', jc.cnt, 'active_count', jc.active_cnt, 'ids', to_jsonb(jc.ids)),
    'journal_open_loops', jsonb_build_object('present', jol.cnt > 0, 'count', jol.cnt, 'open_count', jol.open_cnt, 'ids', to_jsonb(jol.ids)),
    'redline_thread', jsonb_build_object('present', rt.cnt > 0, 'count', rt.cnt),
    'context_materialization', jsonb_build_object(
      'staleness_status', meta.staleness_status,
      'refreshed_at_utc', meta.refreshed_at_utc,
      'latest_pipeline_activity_at_utc', meta.latest_pipeline_activity_at_utc
    )
  ) as node_statuses,
  calls.ids as calls_raw_ids,
  coalesce((select array_agg(i2.interaction_id order by i2.ingested_at_utc desc) from i i2), array[]::text[]) as interaction_ids,
  spans.ids as span_ids,
  evidence.ids as evidence_event_ids,
  attrs.ids as span_attribution_ids,
  rq.ids as review_queue_ids,
  jc.ids as journal_claim_ids,
  jol.ids as journal_open_loop_ids,
  rt.cnt as redline_thread_rows,
  meta.staleness_status as context_staleness_status,
  meta.refreshed_at_utc as context_refreshed_at_utc,
  meta.latest_pipeline_activity_at_utc
from calls
cross join spans
cross join evidence
cross join attrs
cross join rq
cross join jc
cross join jol
cross join rt
cross join meta
left join i_latest il on true;
$$;

comment on function public.redline_truth_graph_v1(text) is
'Given interaction_id, returns node statuses/IDs across calls_raw->interactions->spans->evidence->attribution->review->journal->redline projection with lane label.';

comment on function public.record_redline_defect_event_v1(text, text, text, text, uuid, uuid, uuid, jsonb, jsonb, text) is
'Upsert-style defect event writer for Redline truth-forcing defect SSOT.';

-- Bootstrap context metadata row so health view is immediately queryable.
select
  meta_id,
  refreshed_at_utc,
  activity_anchor_at_utc,
  staleness_status_at_refresh
from public.record_project_context_materialization_refresh_v1(
  'migration_20260228161000',
  'v1',
  array['v_project_feed'],
  'success',
  'bootstrap row from redline truth-forcing migration'
);

commit;
