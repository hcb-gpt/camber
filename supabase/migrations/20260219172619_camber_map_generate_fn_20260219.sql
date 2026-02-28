begin;

-- Generates facts.json + map.json from live catalog + runtime lineage edges
create or replace function public.camber_map_generate_json()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  facts jsonb;
  map jsonb;
  nodes jsonb;
  edges jsonb;
  updated_at text;
  mig int;
  tbl int;
  vw int;
  fnc int;
  ext int;
  rt_count int;
begin
  updated_at := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  select count(*)::int into mig from supabase_migrations.schema_migrations;
  select count(*)::int into tbl from information_schema.tables where table_schema='public' and table_type='BASE TABLE';
  select count(*)::int into vw from information_schema.tables where table_schema='public' and table_type='VIEW';
  select count(*)::int into fnc from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';
  select count(*)::int into ext from pg_extension;

  select count(*)::int into rt_count from public.system_lineage_edges;

  facts := jsonb_build_object(
    'updated_at', updated_at,
    'mode', 'live_product',
    'db', jsonb_build_object(
      'applied_migrations', mig,
      'tables', tbl,
      'views', vw,
      'functions', fnc,
      'extensions', ext
    ),
    'runtime_lineage', jsonb_build_object('count', rt_count)
  );

  -- Nodes: tables/views/matviews
  nodes := (
    select jsonb_agg(
      jsonb_build_object(
        'id', case c.relkind when 'r' then 'table:public.'||c.relname when 'v' then 'view:public.'||c.relname else 'matview:public.'||c.relname end,
        'kind', case c.relkind when 'r' then 'table' when 'v' then 'view' else 'matview' end,
        'group', 'db',
        'schema', 'public',
        'name', c.relname,
        'title', 'public.'||c.relname
      )
    )
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','v','m')
  );

  -- Add functions
  nodes := coalesce(nodes, '[]'::jsonb) || (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', 'fn:public.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
        'kind', 'fn',
        'group', 'db',
        'schema', 'public',
        'name', p.proname,
        'title', 'public.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
      )
    ), '[]'::jsonb)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
  );

  -- Add extensions
  nodes := nodes || (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', 'ext:'||extname,
        'kind', 'ext',
        'group', 'db',
        'schema', null,
        'name', extname,
        'title', 'extension:'||extname
      )
    ), '[]'::jsonb)
    from pg_extension
  );

  -- Edges: view depends_on
  edges := (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'from', case v.relkind when 'v' then 'view:public.'||v.relname else 'matview:public.'||v.relname end,
        'to', case r.relkind when 'r' then 'table:public.'||r.relname when 'v' then 'view:public.'||r.relname else 'matview:public.'||r.relname end,
        'type', 'depends_on'
      )
    ), '[]'::jsonb)
    from pg_class v
    join pg_namespace vn on vn.oid=v.relnamespace
    join pg_rewrite rw on rw.ev_class=v.oid
    join pg_depend d on d.objid=rw.oid
    join pg_class r on r.oid=d.refobjid
    join pg_namespace rn on rn.oid=r.relnamespace
    where vn.nspname='public' and v.relkind in ('v','m') and d.refclassid='pg_class'::regclass and rn.nspname='public'
  );

  -- Edges: function reads_writes
  edges := edges || (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'from', 'fn:public.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
        'to', case r.relkind when 'r' then 'table:public.'||r.relname when 'v' then 'view:public.'||r.relname else 'matview:public.'||r.relname end,
        'type', 'reads_writes'
      )
    ), '[]'::jsonb)
    from pg_proc p
    join pg_namespace pn on pn.oid=p.pronamespace
    join pg_depend d on d.objid=p.oid
    join pg_class r on r.oid=d.refobjid
    join pg_namespace rn on rn.oid=r.relnamespace
    where pn.nspname='public' and d.refclassid='pg_class'::regclass and rn.nspname='public'
  );

  -- Runtime lineage edges
  edges := edges || (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'from', from_node_id,
        'to', to_node_id,
        'type', edge_type,
        'meta', jsonb_build_object(
          'last_seen_at_utc', to_char(last_seen_at_utc at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'seen_count', seen_count,
          'last_evidence_event_id', last_evidence_event_id,
          'meta', meta
        )
      )
    ), '[]'::jsonb)
    from public.system_lineage_edges
  );

  map := jsonb_build_object(
    'updated_at', updated_at,
    'mode', 'live_product',
    'nodes', coalesce(nodes, '[]'::jsonb),
    'edges', coalesce(edges, '[]'::jsonb),
    'groups', jsonb_build_object(
      'db', jsonb_build_object('label','Database'),
      'runtime', jsonb_build_object('label','Runtime Lineage')
    )
  );

  return jsonb_build_object('facts', facts, 'map', map);
end;
$fn$;

comment on function public.camber_map_generate_json is 'Generates camber-map facts+map JSON from live catalog and runtime lineage edges.';

commit;
;
