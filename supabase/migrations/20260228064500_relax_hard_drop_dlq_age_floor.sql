-- Allow operator/manual DLQ sweeps with p_age_hours=0 for immediate triage/testing.

create or replace function public.run_hard_drop_dlq_sweep(
  p_retry_threshold integer default 3,
  p_age_hours numeric default 24,
  p_actor text default 'system:hard_drop_dlq_sweep'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_candidates integer := 0;
  v_upserted integer := 0;
  v_open_count integer := 0;
begin
  with candidates as (
    select
      rq.span_id,
      rq.interaction_id,
      coalesce(rq.hit_count, 1) as retry_count,
      extract(epoch from (now() - coalesce(rq.updated_at, rq.created_at))) / 3600.0 as age_hours
    from public.review_queue rq
    join public.conversation_spans cs on cs.id = rq.span_id
    where rq.status = 'pending'
      and coalesce(cs.is_superseded, false) = false
      and rq.interaction_id not like 'cll_SHADOW%'
      and rq.interaction_id not like 'cll_RACECHK%'
      and rq.interaction_id not like 'cll_DEV%'
      and rq.interaction_id not like 'cll_CHAIN%'
      and coalesce(rq.hit_count, 1) >= greatest(coalesce(p_retry_threshold, 3), 1)
      and extract(epoch from (now() - coalesce(rq.updated_at, rq.created_at))) / 3600.0 >= greatest(coalesce(p_age_hours, 24), 0)
  ),
  upserted as (
    insert into public.hard_drop_dlq (
      span_id,
      interaction_id,
      first_enqueued_at,
      last_enqueued_at,
      retry_count,
      age_hours,
      dlq_reason,
      status,
      metadata,
      updated_at
    )
    select
      c.span_id,
      c.interaction_id,
      now(),
      now(),
      c.retry_count,
      round(c.age_hours::numeric, 3),
      'retry_threshold_exceeded',
      'open',
      jsonb_build_object(
        'actor', coalesce(nullif(trim(p_actor), ''), 'system:hard_drop_dlq_sweep'),
        'retry_threshold', greatest(coalesce(p_retry_threshold, 3), 1),
        'age_hours_threshold', greatest(coalesce(p_age_hours, 24), 0),
        'swept_at_utc', now()
      ),
      now()
    from candidates c
    on conflict (span_id) do update
      set
        interaction_id = excluded.interaction_id,
        last_enqueued_at = now(),
        retry_count = greatest(public.hard_drop_dlq.retry_count, excluded.retry_count),
        age_hours = excluded.age_hours,
        dlq_reason = excluded.dlq_reason,
        status = 'open',
        metadata = coalesce(public.hard_drop_dlq.metadata, '{}'::jsonb) || excluded.metadata,
        updated_at = now()
    returning span_id
  )
  select
    (select count(*)::int from candidates),
    (select count(*)::int from upserted)
  into v_candidates, v_upserted;

  select count(*)::int
  into v_open_count
  from public.hard_drop_dlq
  where status = 'open';

  return jsonb_build_object(
    'ok', true,
    'candidates', v_candidates,
    'upserted', v_upserted,
    'open_dlq_count', v_open_count
  );
end;
$$;

