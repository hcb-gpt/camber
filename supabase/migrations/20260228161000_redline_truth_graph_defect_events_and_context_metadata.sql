begin;

-- 1) Defect event SSOT
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
      'unknown'
    )
  ),
  owner_lane text not null check (
    owner_lane in ('ingestion', 'segmentation', 'attribution', 'journal', 'projection', 'client')
  ),
  interaction_id text,
  thread_id text,
  span_id uuid,
  evidence_event_id uuid,
  project_id uuid,
  first_seen_at_utc timestamptz not null default now(),
  last_seen_at_utc timestamptz not null default now(),
  current_status text not null default 'open' check (current_status in ('open', 'closed')),
  closure_proof jsonb not null default '{}'::jsonb,
  closure_receipt text,
  created_by text not null default 'system:redline_truth_graph',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_redline_defect_events_interaction_status
  on public.redline_defect_events (interaction_id, current_status, last_seen_at_utc desc);

create index if not exists idx_redline_defect_events_project_status
  on public.redline_defect_events (project_id, current_status, last_seen_at_utc desc);

create index if not exists idx_redline_defect_events_lane_type
  on public.redline_defect_events (owner_lane, defect_type, current_status);

create unique index if not exists uq_redline_defect_events_open_identity
  on public.redline_defect_events (
    defect_type,
    owner_lane,
    coalesce(interaction_id, ''),
    coalesce(span_id::text, ''),
    coalesce(project_id::text, '')
  )
  where current_status = 'open';

create or replace function public.trg_set_redline_defect_events_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_set_redline_defect_events_updated_at on public.redline_defect_events;
create trigger trg_set_redline_defect_events_updated_at
before update on public.redline_defect_events
for each row execute function public.trg_set_redline_defect_events_updated_at();

create or replace function public.upsert_redline_defect_event_v1(
  p_defect_type text,
  p_owner_lane text,
  p_interaction_id text default null,
  p_thread_id text default null,
  p_span_id uuid default null,
  p_evidence_event_id uuid default null,
  p_project_id uuid default null,
  p_closure_proof jsonb default '{}'::jsonb,
  p_current_status text default 'open',
  p_closure_receipt text default null,
  p_created_by text default 'system:redline_truth_graph'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_defect_event_id uuid;
begin
  update public.redline_defect_events d
     set last_seen_at_utc = now(),
         thread_id = coalesce(p_thread_id, d.thread_id),
         evidence_event_id = coalesce(p_evidence_event_id, d.evidence_event_id),
         closure_proof = case
           when p_closure_proof is null then d.closure_proof
           else d.closure_proof || p_closure_proof
         end,
         current_status = coalesce(p_current_status, d.current_status),
         closure_receipt = coalesce(p_closure_receipt, d.closure_receipt),
         project_id = coalesce(p_project_id, d.project_id)
   where d.current_status = 'open'
     and d.defect_type = p_defect_type
     and d.owner_lane = p_owner_lane
     and coalesce(d.interaction_id, '') = coalesce(p_interaction_id, '')
     and coalesce(d.span_id::text, '') = coalesce(p_span_id::text, '')
     and coalesce(d.project_id::text, '') = coalesce(p_project_id::text, '')
  returning d.defect_event_id into v_defect_event_id;

  if v_defect_event_id is null then
    insert into public.redline_defect_events (
      defect_type,
      owner_lane,
      interaction_id,
      thread_id,
      span_id,
      evidence_event_id,
      project_id,
      first_seen_at_utc,
      last_seen_at_utc,
      current_status,
      closure_proof,
      closure_receipt,
      created_by
    )
    values (
      p_defect_type,
      p_owner_lane,
      p_interaction_id,
      p_thread_id,
      p_span_id,
      p_evidence_event_id,
      p_project_id,
      now(),
      now(),
      coalesce(p_current_status, 'open'),
      coalesce(p_closure_proof, '{}'::jsonb),
      p_closure_receipt,
      coalesce(p_created_by, 'system:redline_truth_graph')
    )
    returning defect_event_id into v_defect_event_id;
  end if;

  return v_defect_event_id;
end;
$$;

comment on table public.redline_defect_events is
  'SSOT event log for Redline truth-forcing defects with lane ownership and closure proofs.';

comment on function public.upsert_redline_defect_event_v1(text, text, text, text, uuid, uuid, uuid, jsonb, text, text, text) is
  'Idempotent defect-event upsert keyed on open defect identity (type+lane+interaction/span/project).';

-- 2) Truth graph query surface
create or replace function public.redline_truth_graph_v1(p_interaction_id text)
returns table (
  interaction_id text,
  interaction_uuid uuid,
  project_id uuid,
  defect_type text,
  lane_label text,
  graph jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_interaction_uuid uuid;
  v_project_id uuid;

  v_calls_raw_ids text[];
  v_span_ids text[];
  v_evidence_event_ids text[];
  v_span_attribution_ids text[];
  v_review_queue_ids text[];
  v_journal_claim_ids text[];
  v_open_loop_ids text[];

  v_calls_raw_count integer := 0;
  v_interaction_count integer := 0;
  v_span_count integer := 0;
  v_evidence_count integer := 0;
  v_span_attr_count integer := 0;
  v_review_pending_count integer := 0;
  v_journal_claim_count integer := 0;
  v_open_loop_count integer := 0;

  v_defect_type text := 'none';
  v_lane_label text := 'healthy';
  v_graph jsonb;
begin
  select i.id, i.project_id
    into v_interaction_uuid, v_project_id
  from public.interactions i
  where i.interaction_id = p_interaction_id
  order by i.event_at_utc desc nulls last
  limit 1;

  v_interaction_count := case when v_interaction_uuid is null then 0 else 1 end;

  select coalesce(array_agg(cr.id::text order by cr.event_at_utc desc nulls last), '{}'::text[]), count(*)::int
    into v_calls_raw_ids, v_calls_raw_count
  from public.calls_raw cr
  where cr.interaction_id = p_interaction_id;

  select coalesce(array_agg(cs.id::text order by cs.created_at desc nulls last), '{}'::text[]), count(*)::int
    into v_span_ids, v_span_count
  from public.conversation_spans cs
  where cs.interaction_id = p_interaction_id
    and coalesce(cs.is_superseded, false) = false;

  select coalesce(array_agg(ee.evidence_event_id::text order by ee.created_at desc nulls last), '{}'::text[]), count(*)::int
    into v_evidence_event_ids, v_evidence_count
  from public.evidence_events ee
  where ee.source_id = p_interaction_id
     or coalesce(ee.metadata->>'interaction_id', '') = p_interaction_id;

  select coalesce(array_agg(sa.id::text order by sa.applied_at_utc desc nulls last), '{}'::text[]), count(*)::int
    into v_span_attribution_ids, v_span_attr_count
  from public.span_attributions sa
  where sa.span_id::text = any(coalesce(v_span_ids, '{}'::text[]));

  select coalesce(array_agg(rq.id::text order by rq.created_at desc nulls last), '{}'::text[]), count(*)::int
    into v_review_queue_ids, v_review_pending_count
  from public.review_queue rq
  where rq.interaction_id = p_interaction_id
    and rq.status = 'pending';

  select coalesce(array_agg(jc.id::text order by jc.created_at desc nulls last), '{}'::text[]), count(*)::int
    into v_journal_claim_ids, v_journal_claim_count
  from public.journal_claims jc
  where jc.call_id = p_interaction_id
    and coalesce(jc.active, true) = true;

  select coalesce(array_agg(jol.id::text order by jol.created_at desc nulls last), '{}'::text[]), count(*)::int
    into v_open_loop_ids, v_open_loop_count
  from public.journal_open_loops jol
  where jol.call_id = p_interaction_id
    and jol.status = 'open';

  -- Lane label logic: first failing node determines owner lane + defect type.
  if v_interaction_count = 0 and v_calls_raw_count > 0 then
    v_defect_type := 'projection_gap';
    v_lane_label := 'projection';
  elsif v_calls_raw_count = 0 then
    v_defect_type := 'ingestion_missing';
    v_lane_label := 'ingestion';
  elsif v_span_count = 0 then
    v_defect_type := 'projection_gap';
    v_lane_label := 'segmentation';
  elsif v_evidence_count = 0 then
    v_defect_type := 'missing_evidence';
    v_lane_label := 'journal';
  elsif v_span_attr_count = 0 then
    v_defect_type := 'missing_attribution';
    v_lane_label := 'attribution';
  elsif v_project_id is null then
    v_defect_type := 'projection_gap';
    v_lane_label := 'projection';
  elsif v_review_pending_count > 0 then
    v_defect_type := 'missing_attribution';
    v_lane_label := 'attribution';
  else
    v_defect_type := 'unknown';
    v_lane_label := 'client';
  end if;

  v_graph := jsonb_build_object(
    'nodes', jsonb_build_object(
      'calls_raw', jsonb_build_object(
        'status', case when v_calls_raw_count > 0 then 'present' else 'missing' end,
        'count', v_calls_raw_count,
        'ids', to_jsonb(v_calls_raw_ids),
        'lane_if_missing', 'ingestion'
      ),
      'interactions', jsonb_build_object(
        'status', case when v_interaction_count > 0 then 'present' else 'missing' end,
        'count', v_interaction_count,
        'ids', to_jsonb(case when v_interaction_uuid is null then '{}'::text[] else array[v_interaction_uuid::text] end),
        'lane_if_missing', 'projection'
      ),
      'conversation_spans', jsonb_build_object(
        'status', case when v_span_count > 0 then 'present' else 'missing' end,
        'count', v_span_count,
        'ids', to_jsonb(v_span_ids),
        'lane_if_missing', 'segmentation'
      ),
      'evidence_events', jsonb_build_object(
        'status', case when v_evidence_count > 0 then 'present' else 'missing' end,
        'count', v_evidence_count,
        'ids', to_jsonb(v_evidence_event_ids),
        'lane_if_missing', 'journal'
      ),
      'span_attributions', jsonb_build_object(
        'status', case when v_span_attr_count > 0 then 'present' else 'missing' end,
        'count', v_span_attr_count,
        'ids', to_jsonb(v_span_attribution_ids),
        'lane_if_missing', 'attribution'
      ),
      'review_queue_pending', jsonb_build_object(
        'status', case when v_review_pending_count > 0 then 'pending' else 'clear' end,
        'count', v_review_pending_count,
        'ids', to_jsonb(v_review_queue_ids),
        'lane_if_missing', 'attribution'
      ),
      'journal_claims', jsonb_build_object(
        'status', case when v_journal_claim_count > 0 then 'present' else 'none' end,
        'count', v_journal_claim_count,
        'ids', to_jsonb(v_journal_claim_ids),
        'lane_if_missing', 'journal'
      ),
      'journal_open_loops', jsonb_build_object(
        'status', case when v_open_loop_count > 0 then 'open' else 'none' end,
        'count', v_open_loop_count,
        'ids', to_jsonb(v_open_loop_ids),
        'lane_if_missing', 'client'
      )
    ),
    'summary', jsonb_build_object(
      'interaction_id', p_interaction_id,
      'interaction_uuid', v_interaction_uuid,
      'project_id', v_project_id,
      'defect_type', v_defect_type,
      'lane_label', v_lane_label
    )
  );

  return query
  select p_interaction_id, v_interaction_uuid, v_project_id, v_defect_type, v_lane_label, v_graph;
end;
$$;

comment on function public.redline_truth_graph_v1(text) is
  'Returns node-by-node Redline truth graph status for one interaction with lane label logic.';

grant execute on function public.redline_truth_graph_v1(text)
  to authenticated, anon, service_role;

-- 3) Gas-station context metadata + staleness anchored to pipeline success.
create table if not exists public.context_surface_refresh_metadata (
  context_surface_metadata_id uuid primary key default gen_random_uuid(),
  surface_name text not null,
  project_id uuid,
  context_version text not null default 'v1',
  source_views text[] not null default '{}'::text[],
  pipeline_run_id text,
  refreshed_at_utc timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  recorded_at_utc timestamptz not null default now(),
  updated_at_utc timestamptz not null default now()
);

create index if not exists idx_context_surface_refresh_metadata_surface_project
  on public.context_surface_refresh_metadata (surface_name, project_id, refreshed_at_utc desc);

create unique index if not exists uq_context_surface_refresh_metadata_global_surface
  on public.context_surface_refresh_metadata (surface_name)
  where project_id is null;

create unique index if not exists uq_context_surface_refresh_metadata_surface_project
  on public.context_surface_refresh_metadata (surface_name, project_id)
  where project_id is not null;

create or replace function public.trg_set_context_surface_refresh_metadata_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at_utc := now();
  return new;
end;
$$;

drop trigger if exists trg_set_context_surface_refresh_metadata_updated_at on public.context_surface_refresh_metadata;
create trigger trg_set_context_surface_refresh_metadata_updated_at
before update on public.context_surface_refresh_metadata
for each row execute function public.trg_set_context_surface_refresh_metadata_updated_at();

create or replace function public.upsert_context_surface_refresh_metadata_v1(
  p_surface_name text,
  p_project_id uuid default null,
  p_context_version text default 'v1',
  p_source_views text[] default '{}'::text[],
  p_pipeline_run_id text default null,
  p_refreshed_at_utc timestamptz default now(),
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  update public.context_surface_refresh_metadata m
     set context_version = coalesce(p_context_version, m.context_version),
         source_views = coalesce(p_source_views, m.source_views),
         pipeline_run_id = coalesce(p_pipeline_run_id, m.pipeline_run_id),
         refreshed_at_utc = coalesce(p_refreshed_at_utc, m.refreshed_at_utc),
         metadata = m.metadata || coalesce(p_metadata, '{}'::jsonb)
   where m.surface_name = p_surface_name
     and m.project_id is not distinct from p_project_id
  returning m.context_surface_metadata_id into v_id;

  if v_id is null then
    insert into public.context_surface_refresh_metadata (
      surface_name,
      project_id,
      context_version,
      source_views,
      pipeline_run_id,
      refreshed_at_utc,
      metadata
    ) values (
      p_surface_name,
      p_project_id,
      coalesce(p_context_version, 'v1'),
      coalesce(p_source_views, '{}'::text[]),
      p_pipeline_run_id,
      coalesce(p_refreshed_at_utc, now()),
      coalesce(p_metadata, '{}'::jsonb)
    )
    returning context_surface_metadata_id into v_id;
  end if;

  return v_id;
end;
$$;

create or replace function public.latest_pipeline_success_anchor_utc_v1(p_project_id uuid default null)
returns timestamptz
language sql
stable
as $$
  with anchor_candidates as (
    -- Primary success anchor: completed/finished successful journal run.
    select max(coalesce(jr.completed_at, jr.finished_at, jr.started_at)) as ts
    from public.journal_runs jr
    where jr.status = 'success'
      and (p_project_id is null or jr.project_id = p_project_id)

    union all

    -- Pipeline log heartbeat (treated as successful progression signal in this environment).
    select max(pl.logged_at_utc) as ts
    from public.pipeline_logs pl
    left join public.interactions i on i.interaction_id = pl.interaction_id
    where lower(pl.log_level) = 'info'
      and (p_project_id is null or i.project_id = p_project_id)

    union all

    -- Ingestion/projection evidence
    select max(i.ingested_at_utc) as ts
    from public.interactions i
    where i.project_id is not null
      and (p_project_id is null or i.project_id = p_project_id)

    union all

    -- Attribution progression
    select max(sa.applied_at_utc) as ts
    from public.span_attributions sa
    where sa.applied_project_id is not null
      and (p_project_id is null or sa.applied_project_id = p_project_id)

    union all

    -- Journal progression
    select max(jc.created_at) as ts
    from public.journal_claims jc
    where coalesce(jc.active, true) = true
      and jc.project_id is not null
      and (p_project_id is null or jc.project_id = p_project_id)
  )
  select max(ts) from anchor_candidates;
$$;

create or replace function public.refresh_redline_context_matviews()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pipeline_run_id text;
  v_refreshed_at_utc timestamptz := now();
begin
  refresh materialized view public.mat_project_context;
  refresh materialized view public.mat_contact_context;
  refresh materialized view public.mat_belief_context;

  select jr.run_id::text
    into v_pipeline_run_id
  from public.journal_runs jr
  where jr.status = 'success'
  order by coalesce(jr.completed_at, jr.finished_at, jr.started_at) desc nulls last
  limit 1;

  perform public.upsert_context_surface_refresh_metadata_v1(
    'mat_project_context',
    null,
    'v1',
    array['v_project_feed']::text[],
    v_pipeline_run_id,
    v_refreshed_at_utc,
    jsonb_build_object(
      'refresh_fn', 'refresh_redline_context_matviews',
      'anchor_rule', 'journal_runs_success',
      'updated_by_migration', '20260228161000_redline_truth_graph_defect_events_and_context_metadata.sql'
    )
  );
end;
$$;

create or replace view public.v_context_surface_staleness_v1 as
with latest_meta as (
  select distinct on (m.surface_name, coalesce(m.project_id::text, '__GLOBAL__'))
    m.context_surface_metadata_id,
    m.surface_name,
    m.project_id,
    m.context_version,
    m.source_views,
    m.pipeline_run_id,
    m.refreshed_at_utc,
    m.metadata,
    m.recorded_at_utc,
    m.updated_at_utc
  from public.context_surface_refresh_metadata m
  order by m.surface_name, coalesce(m.project_id::text, '__GLOBAL__'), m.refreshed_at_utc desc, m.updated_at_utc desc
)
select
  lm.context_surface_metadata_id,
  lm.surface_name,
  lm.project_id,
  lm.context_version,
  lm.source_views,
  lm.pipeline_run_id,
  lm.refreshed_at_utc,
  pa.pipeline_success_at_utc,
  case
    when pa.pipeline_success_at_utc is null then null
    when lm.refreshed_at_utc < pa.pipeline_success_at_utc - interval '5 minutes' then true
    else false
  end as is_stale,
  case
    when pa.pipeline_success_at_utc is null then null
    else greatest(extract(epoch from (pa.pipeline_success_at_utc - lm.refreshed_at_utc))::bigint, 0)
  end as lag_seconds,
  case
    when pa.pipeline_success_at_utc is null then 'no_pipeline_anchor'
    when lm.refreshed_at_utc < pa.pipeline_success_at_utc - interval '5 minutes' then 'stale_vs_pipeline_success'
    else 'fresh_vs_pipeline_success'
  end as staleness_rule,
  lm.metadata,
  lm.recorded_at_utc,
  lm.updated_at_utc
from latest_meta lm
cross join lateral (
  select public.latest_pipeline_success_anchor_utc_v1(lm.project_id) as pipeline_success_at_utc
) pa;

comment on table public.context_surface_refresh_metadata is
  'Companion metadata for materialized context surfaces (version/source/pipeline_run_id/refreshed_at).';

comment on view public.v_context_surface_staleness_v1 is
  'Staleness view anchored to latest successful pipeline activity, not generic wall-clock timestamps.';

comment on function public.latest_pipeline_success_anchor_utc_v1(uuid) is
  'Computes latest successful pipeline anchor timestamp (journal_runs success first, then progression fallbacks).';

comment on function public.refresh_redline_context_matviews() is
  'Refreshes Redline context materialized views and records mat_project_context metadata tied to latest successful journal run.';

comment on function public.upsert_context_surface_refresh_metadata_v1(text, uuid, text, text[], text, timestamptz, jsonb) is
  'Upserts one context-surface metadata row by surface/project scope.';

grant select, insert, update on public.redline_defect_events to service_role;
grant select on public.redline_defect_events to authenticated, anon;

grant select, insert, update on public.context_surface_refresh_metadata to service_role;
grant select on public.context_surface_refresh_metadata to authenticated, anon;
grant select on public.v_context_surface_staleness_v1 to authenticated, anon, service_role;

grant execute on function public.upsert_redline_defect_event_v1(text, text, text, text, uuid, uuid, uuid, jsonb, text, text, text)
  to authenticated, anon, service_role;
grant execute on function public.upsert_context_surface_refresh_metadata_v1(text, uuid, text, text[], text, timestamptz, jsonb)
  to authenticated, anon, service_role;
grant execute on function public.latest_pipeline_success_anchor_utc_v1(uuid)
  to authenticated, anon, service_role;
grant execute on function public.refresh_redline_context_matviews()
  to service_role;

-- Seed row for the gas-station context surface contract.
select public.upsert_context_surface_refresh_metadata_v1(
  'mat_project_context',
  null,
  'v1',
  array['v_project_feed']::text[],
  (
    select jr.run_id::text
    from public.journal_runs jr
    where jr.status = 'success'
    order by coalesce(jr.completed_at, jr.finished_at, jr.started_at) desc nulls last
    limit 1
  ),
  now(),
  jsonb_build_object('seeded_by', '20260228161000_redline_truth_graph_defect_events_and_context_metadata.sql')
);

commit;
