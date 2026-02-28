-- Stores raw review swarm batches for audit/debug.
create table if not exists public.review_swarm_batches (
  id uuid primary key default gen_random_uuid(),
  batch_label text not null,
  created_at_utc timestamptz null,
  source text null,
  payload jsonb not null,
  inserted_at timestamptz not null default now(),
  ingested_at timestamptz null,
  ingest_status text not null default 'stored',
  unique (batch_label, created_at_utc)
);

create index if not exists idx_review_swarm_batches_inserted_at on public.review_swarm_batches(inserted_at desc);

-- Ingests a "review swarm" JSON payload into review_suggestions.
-- Optional: apply dismiss-only outcomes to review_queue (never auto-assign).
create or replace function public.ingest_review_swarm_batch(
  p_payload jsonb,
  p_prompt_version text default null,
  p_source text default null,
  p_apply_dismiss boolean default false
)
returns table(review_queue_id uuid, suggested_action text)
language plpgsql
as $$
declare
  v_label text;
  v_created_at timestamptz;
  v_prompt_version text;
  v_batch_id uuid;
begin
  v_label := coalesce(p_payload #>> '{batch,label}', 'unknown_batch');
  v_created_at := nullif(p_payload #>> '{batch,created_at_utc}', '')::timestamptz;
  v_prompt_version := coalesce(p_prompt_version, v_label || '_v1');

  -- Store the raw batch (idempotent on label+created_at)
  insert into public.review_swarm_batches(batch_label, created_at_utc, source, payload)
  values (v_label, v_created_at, p_source, p_payload)
  on conflict (batch_label, created_at_utc) do update set
    payload = excluded.payload,
    source = coalesce(excluded.source, public.review_swarm_batches.source),
    inserted_at = now()
  returning id into v_batch_id;

  -- Upsert suggestions
  return query
  with items as (
    select jsonb_array_elements(coalesce(p_payload->'batch'->'items','[]'::jsonb)) as item
  ), norm as (
    select
      nullif(item->>'review_queue_id','')::uuid as review_queue_id,
      nullif(item->>'span_id','')::uuid as span_id,
      nullif(item->>'interaction_id','') as interaction_id,
      nullif(item->>'recommended_action','') as recommended_action,
      nullif(item->>'suggested_project_id','')::uuid as suggested_project_id,
      coalesce((item->>'confidence')::numeric, 0.0) as confidence,
      coalesce(item->'reason_codes','[]'::jsonb) as reason_codes,
      coalesce(item->'evidence','{}'::jsonb) as evidence
    from items
    where nullif(item->>'review_queue_id','') is not null
  ), upserted as (
    insert into public.review_suggestions(
      review_queue_id, span_id, interaction_id, module,
      suggested_action, suggested_project_id, suggestion_confidence,
      rationale, model_id, prompt_version
    )
    select
      n.review_queue_id,
      n.span_id,
      n.interaction_id,
      rq.module,
      case
        when n.recommended_action='DISMISS' then 'dismiss'
        when n.recommended_action='RESOLVE' then 'assign'
        else 'review'
      end as suggested_action,
      n.suggested_project_id,
      least(0.97, greatest(0.01, n.confidence)) as suggestion_confidence,
      (
        'manual_batch='||v_label||
        '; action='||coalesce(n.recommended_action,'')||
        '; reasons='||coalesce(n.reason_codes::text,'[]')||
        '; evidence='||left(coalesce(n.evidence::text,'{}'), 500)
      ) as rationale,
      'human_review_swarm' as model_id,
      v_prompt_version as prompt_version
    from norm n
    left join public.review_queue rq on rq.id = n.review_queue_id
    on conflict (review_queue_id) do update set
      span_id=excluded.span_id,
      interaction_id=excluded.interaction_id,
      module=excluded.module,
      suggested_action=excluded.suggested_action,
      suggested_project_id=excluded.suggested_project_id,
      suggestion_confidence=excluded.suggestion_confidence,
      rationale=excluded.rationale,
      model_id=excluded.model_id,
      prompt_version=excluded.prompt_version,
      created_at=now()
    returning review_queue_id, suggested_action
  )
  select review_queue_id, suggested_action from upserted;

  -- Apply dismiss-only (optional)
  if p_apply_dismiss then
    with d as (
      select rs.review_queue_id
      from public.review_suggestions rs
      where rs.model_id='human_review_swarm'
        and rs.prompt_version=v_prompt_version
        and rs.suggested_action='dismiss'
    )
    update public.review_queue rq
    set
      status='dismissed',
      resolution_action='proxy_manual_dismiss',
      resolved_at=now(),
      resolution_notes=coalesce(rq.resolution_notes,'') ||
        case when coalesce(rq.resolution_notes,'')='' then '' else E'\n' end ||
        ('auto-applied dismiss from manual batch '||v_label)
    where rq.id in (select review_queue_id from d)
      and rq.status='pending';
  end if;

  update public.review_swarm_batches
  set ingested_at = now(), ingest_status='ingested'
  where id = v_batch_id;

end;
$$;
;
