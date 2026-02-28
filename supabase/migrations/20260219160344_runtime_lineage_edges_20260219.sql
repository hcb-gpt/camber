begin;

create table if not exists public.system_lineage_edges (
  edge_id bigserial primary key,
  from_node_id text not null,
  to_node_id text not null,
  edge_type text not null,
  first_seen_at_utc timestamptz not null default now(),
  last_seen_at_utc timestamptz not null default now(),
  seen_count bigint not null default 1,
  last_evidence_event_id uuid null,
  meta jsonb null,
  unique (from_node_id, to_node_id, edge_type)
);

comment on table public.system_lineage_edges is 'Evidence-backed runtime lineage edges; maintained from evidence_events.metadata.edges.';

create index if not exists idx_system_lineage_edges_last_seen
  on public.system_lineage_edges (last_seen_at_utc desc);

create index if not exists idx_system_lineage_edges_from
  on public.system_lineage_edges (from_node_id);

create index if not exists idx_system_lineage_edges_to
  on public.system_lineage_edges (to_node_id);

create or replace function public.upsert_system_lineage_edge(
  p_from text,
  p_to text,
  p_type text,
  p_evidence_event_id uuid,
  p_meta jsonb
) returns void
language plpgsql
set search_path to 'public'
as $fn$
begin
  insert into public.system_lineage_edges(
    from_node_id, to_node_id, edge_type,
    first_seen_at_utc, last_seen_at_utc,
    seen_count,
    last_evidence_event_id,
    meta
  ) values (
    p_from, p_to, p_type,
    now(), now(),
    1,
    p_evidence_event_id,
    p_meta
  )
  on conflict (from_node_id, to_node_id, edge_type)
  do update set
    last_seen_at_utc = excluded.last_seen_at_utc,
    seen_count = public.system_lineage_edges.seen_count + 1,
    last_evidence_event_id = excluded.last_evidence_event_id,
    meta = coalesce(excluded.meta, public.system_lineage_edges.meta);
end;
$fn$;

comment on function public.upsert_system_lineage_edge is 'Upserts a runtime lineage edge with last_seen and count; called by evidence_events trigger.';

create or replace function public.trg_evidence_events_to_lineage_edges()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
declare
  e jsonb;
  arr jsonb;
  i int;
  from_id text;
  to_id text;
  edge_t text;
  meta jsonb;
begin
  if new.metadata is null then
    return new;
  end if;

  arr := new.metadata -> 'edges';
  if arr is null or jsonb_typeof(arr) <> 'array' then
    return new;
  end if;

  for i in 0..jsonb_array_length(arr)-1 loop
    e := arr -> i;
    from_id := e ->> 'from';
    to_id := e ->> 'to';
    edge_t := e ->> 'type';
    meta := e -> 'meta';

    if from_id is null or to_id is null or edge_t is null then
      continue;
    end if;

    perform public.upsert_system_lineage_edge(from_id, to_id, edge_t, new.evidence_event_id, meta);
  end loop;

  return new;
end;
$fn$;

drop trigger if exists evidence_events_lineage_edges on public.evidence_events;
create trigger evidence_events_lineage_edges
after insert on public.evidence_events
for each row execute function public.trg_evidence_events_to_lineage_edges();

commit;
;
