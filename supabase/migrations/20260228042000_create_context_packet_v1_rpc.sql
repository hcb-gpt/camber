begin;

create or replace function public.get_context_packet_v1(
  p_contact_id uuid default null,
  p_project_id uuid default null,
  p_recent_interactions_limit integer default 15,
  p_recent_sms_spans_limit integer default 15,
  p_open_items_limit integer default 25,
  p_window_hours integer default 168
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_window_hours integer := greatest(1, least(coalesce(p_window_hours, 168), 24 * 30));
  v_recent_interactions_limit integer := greatest(1, least(coalesce(p_recent_interactions_limit, 15), 100));
  v_recent_sms_spans_limit integer := greatest(1, least(coalesce(p_recent_sms_spans_limit, 15), 100));
  v_open_items_limit integer := greatest(1, least(coalesce(p_open_items_limit, 25), 200));
  v_window_start timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_window_hours, 168), 24 * 30)));

  v_recent_interactions jsonb := '[]'::jsonb;
  v_recent_sms_spans jsonb := '[]'::jsonb;
  v_pending_review_items jsonb := '[]'::jsonb;
  v_ungraded_claims jsonb := '[]'::jsonb;
  v_open_loops jsonb := '[]'::jsonb;
  v_active_scheduler_items jsonb := '[]'::jsonb;

  v_pending_review_count bigint := 0;
  v_ungraded_claim_count bigint := 0;
  v_open_loop_count bigint := 0;
  v_active_scheduler_count bigint := 0;

  v_packet jsonb;
begin
  -- recent interactions for requested scope and time window
  select coalesce(jsonb_agg(to_jsonb(r) order by r.event_at_utc desc), '[]'::jsonb)
  into v_recent_interactions
  from (
    select
      i.interaction_id,
      i.id as interaction_uuid,
      i.channel,
      i.event_at_utc,
      i.contact_id,
      i.project_id,
      left(coalesce(i.human_summary, ''), 280) as summary_snippet,
      cs.id as span_id
    from public.interactions i
    left join lateral (
      select s.id
      from public.conversation_spans s
      where s.interaction_id = i.interaction_id
        and coalesce(s.is_superseded, false) = false
      order by s.created_at desc
      limit 1
    ) cs on true
    where i.event_at_utc >= v_window_start
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (p_project_id is null or i.project_id = p_project_id)
    order by i.event_at_utc desc nulls last
    limit v_recent_interactions_limit
  ) r;

  -- recent sms spans (span-level pointers for sms_thread interactions)
  select coalesce(jsonb_agg(to_jsonb(sx) order by sx.created_at desc), '[]'::jsonb)
  into v_recent_sms_spans
  from (
    select
      cs.id as span_id,
      cs.interaction_id,
      cs.span_index,
      cs.char_start,
      cs.char_end,
      cs.created_at,
      i.contact_id,
      i.project_id
    from public.conversation_spans cs
    left join public.interactions i
      on i.interaction_id = cs.interaction_id
    where cs.created_at >= v_window_start
      and cs.interaction_id like 'sms_thread_%'
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (p_project_id is null or i.project_id = p_project_id)
    order by cs.created_at desc
    limit v_recent_sms_spans_limit
  ) sx;

  -- pending review_queue workload
  select count(*)::bigint
  into v_pending_review_count
  from public.review_queue rq
  left join public.interactions i
    on i.interaction_id = rq.interaction_id
  where rq.status = 'pending'
    and rq.created_at >= v_window_start
    and (p_contact_id is null or i.contact_id = p_contact_id)
    and (p_project_id is null or i.project_id = p_project_id);

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
  into v_pending_review_items
  from (
    select
      rq.id as review_queue_id,
      rq.interaction_id,
      rq.span_id,
      rq.claim_id,
      rq.module,
      rq.reason_codes,
      rq.created_at,
      i.contact_id,
      i.project_id
    from public.review_queue rq
    left join public.interactions i
      on i.interaction_id = rq.interaction_id
    where rq.status = 'pending'
      and rq.created_at >= v_window_start
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (p_project_id is null or i.project_id = p_project_id)
    order by rq.created_at desc nulls last
    limit v_open_items_limit
  ) q;

  -- ungraded active journal claims
  select count(*)::bigint
  into v_ungraded_claim_count
  from public.journal_claims jc
  left join public.claim_grades cg
    on cg.claim_id = jc.claim_id
  left join public.interactions i
    on i.interaction_id = jc.call_id
  where coalesce(jc.active, true) = true
    and cg.id is null
    and jc.created_at >= v_window_start
    and (p_contact_id is null or i.contact_id = p_contact_id)
    and (
      p_project_id is null
      or coalesce(jc.project_id, jc.claim_project_id, jc.claim_project_id_norm) = p_project_id
    );

  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb)
  into v_ungraded_claims
  from (
    select
      jc.claim_id,
      jc.id as journal_claim_row_id,
      jc.call_id as interaction_id,
      jc.source_span_id as span_id,
      coalesce(jc.project_id, jc.claim_project_id, jc.claim_project_id_norm) as project_id,
      i.contact_id,
      jc.claim_type,
      left(coalesce(jc.claim_text, ''), 240) as claim_text_snippet,
      jc.claim_confirmation_state,
      jc.created_at
    from public.journal_claims jc
    left join public.claim_grades cg
      on cg.claim_id = jc.claim_id
    left join public.interactions i
      on i.interaction_id = jc.call_id
    where coalesce(jc.active, true) = true
      and cg.id is null
      and jc.created_at >= v_window_start
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (
        p_project_id is null
        or coalesce(jc.project_id, jc.claim_project_id, jc.claim_project_id_norm) = p_project_id
      )
    order by jc.created_at desc nulls last
    limit v_open_items_limit
  ) c;

  -- open loops
  select count(*)::bigint
  into v_open_loop_count
  from public.journal_open_loops ol
  left join public.interactions i
    on i.interaction_id = ol.call_id
  where ol.status = 'open'
    and ol.created_at >= v_window_start
    and (p_contact_id is null or i.contact_id = p_contact_id)
    and (p_project_id is null or ol.project_id = p_project_id);

  select coalesce(jsonb_agg(to_jsonb(olx) order by olx.created_at desc), '[]'::jsonb)
  into v_open_loops
  from (
    select
      ol.id as open_loop_id,
      ol.call_id as interaction_id,
      ol.project_id,
      i.contact_id,
      ol.loop_type,
      left(coalesce(ol.description, ''), 240) as description_snippet,
      ol.created_at
    from public.journal_open_loops ol
    left join public.interactions i
      on i.interaction_id = ol.call_id
    where ol.status = 'open'
      and ol.created_at >= v_window_start
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (p_project_id is null or ol.project_id = p_project_id)
    order by ol.created_at desc nulls last
    limit v_open_items_limit
  ) olx;

  -- active scheduler items
  select count(*)::bigint
  into v_active_scheduler_count
  from public.scheduler_items si
  left join public.interactions i
    on i.id = si.interaction_id
  where si.status = 'pending'
    and si.created_at >= v_window_start
    and (p_contact_id is null or i.contact_id = p_contact_id)
    and (p_project_id is null or si.project_id = p_project_id);

  select coalesce(jsonb_agg(to_jsonb(sq) order by sq.created_at desc), '[]'::jsonb)
  into v_active_scheduler_items
  from (
    select
      si.id as scheduler_item_id,
      i.interaction_id,
      null::uuid as span_id,
      si.project_id,
      i.contact_id,
      si.item_type,
      si.status,
      left(coalesce(si.title, ''), 160) as title_snippet,
      si.created_at
    from public.scheduler_items si
    left join public.interactions i
      on i.id = si.interaction_id
    where si.status = 'pending'
      and si.created_at >= v_window_start
      and (p_contact_id is null or i.contact_id = p_contact_id)
      and (p_project_id is null or si.project_id = p_project_id)
    order by si.created_at desc nulls last
    limit v_open_items_limit
  ) sq;

  v_packet := jsonb_build_object(
    'packet_version', 'context_packet_v1',
    'generated_at_utc', v_now,
    'filters', jsonb_build_object(
      'contact_id', p_contact_id,
      'project_id', p_project_id,
      'window_hours', v_window_hours
    ),
    'materialized_at_utc', jsonb_build_object(
      'mat_project_context', (select max(materialized_at_utc) from public.mat_project_context),
      'mat_contact_context', (select max(materialized_at_utc) from public.mat_contact_context),
      'mat_belief_context', (select max(materialized_at_utc) from public.mat_belief_context)
    ),
    'recent', jsonb_build_object(
      'interactions', v_recent_interactions,
      'sms_spans', v_recent_sms_spans
    ),
    'open', jsonb_build_object(
      'pending_review_queue', jsonb_build_object(
        'count', v_pending_review_count,
        'items', v_pending_review_items
      ),
      'ungraded_claims', jsonb_build_object(
        'count', v_ungraded_claim_count,
        'items', v_ungraded_claims
      ),
      'active_open_loops', jsonb_build_object(
        'count', v_open_loop_count,
        'items', v_open_loops
      ),
      'active_scheduler_items', jsonb_build_object(
        'count', v_active_scheduler_count,
        'items', v_active_scheduler_items
      )
    ),
    'limits', jsonb_build_object(
      'recent_interactions_limit', v_recent_interactions_limit,
      'recent_sms_spans_limit', v_recent_sms_spans_limit,
      'open_items_limit', v_open_items_limit,
      'truncation_order', 'most_recent_first'
    )
  );

  return v_packet;
end;
$$;

comment on function public.get_context_packet_v1(uuid, uuid, integer, integer, integer, integer) is
  'Returns context_packet_v1 JSON for Redline assistant: matview freshness, recent interactions/sms spans, and open pending items (review queue, ungraded claims, open loops, scheduler).';

grant execute on function public.get_context_packet_v1(uuid, uuid, integer, integer, integer, integer)
  to service_role, authenticated, anon;

commit;
