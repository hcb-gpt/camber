-- Fix assistant_context_v1: surface SMS highlights + anchored-project fallback
--
-- Bug: The highlights CTE joined redline_thread (UNION of calls + SMS) back to
-- interactions via i.id = rt.interaction_id. For SMS rows, interaction_id holds
-- sms_messages.id which has no match in interactions.id — silently dropping ALL
-- SMS data from assistant highlights.
--
-- Additionally, the WHERE i.project_id IS NOT NULL filter excluded any call
-- interactions that hadn't been attributed to a project yet.
--
-- Fix: Replace the single highlights CTE with two source CTEs:
--   1) call_highlights: direct from interactions (with anchored-project fallback)
--   2) sms_highlights: from sms_messages via contact phone → anchored project
--
-- Perf: get_contact_anchored_project_id() is resolved once per row via sub-CTEs
-- (interaction_with_project, sms_with_project) to avoid double function evaluation.
--
-- Sections 1 (roster) and 3 (contact candidates) are unchanged.

begin;

create or replace function public.assistant_context_v1(
  p_window_hours integer default 24,
  p_projects_limit integer default 100,
  p_highlights_per_project integer default 5,
  p_contacts_limit integer default 200,
  p_candidates_per_contact integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_window_hours integer := greatest(1, least(coalesce(p_window_hours, 24), 24 * 30));
  v_projects_limit integer := greatest(1, least(coalesce(p_projects_limit, 100), 1000));
  v_highlights_per_project integer := greatest(1, least(coalesce(p_highlights_per_project, 5), 25));
  v_contacts_limit integer := greatest(1, least(coalesce(p_contacts_limit, 200), 2000));
  v_candidates_per_contact integer := greatest(1, least(coalesce(p_candidates_per_contact, 5), 20));

  v_projects_roster jsonb := '[]'::jsonb;
  v_project_recent_highlights jsonb := '[]'::jsonb;
  v_contact_project_candidates jsonb := '[]'::jsonb;
begin
  -- 1) Project roster: canonical project list for assistant grounding.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', pr.id,
        'name', pr.name,
        'status', pr.status
      )
      order by pr.name asc
    ),
    '[]'::jsonb
  )
  into v_projects_roster
  from (
    select p.id, p.name, p.status
    from public.projects p
    order by p.updated_at desc nulls last, p.name asc
    limit v_projects_limit
  ) pr;

  -- 2) Per-project recent highlights from CALLS + SMS (two-path query).
  --
  -- Path A: Call interactions — use project_id directly, fall back to
  --         anchored project via contact_id if project_id is NULL.
  --         Sub-CTE resolves project once per row to avoid double function call.
  -- Path B: SMS messages — resolve project via contact phone → anchored project.
  --         Same sub-CTE pattern for SMS.
  with interaction_with_project as (
    select
      i.*,
      coalesce(i.project_id, public.get_contact_anchored_project_id(i.contact_id)) as resolved_project_id
    from public.interactions i
    where i.event_at_utc >= v_now - make_interval(hours => v_window_hours)
  ),
  call_highlights as (
    select
      ip.resolved_project_id as project_id,
      ip.interaction_id::text as interaction_id,
      ip.event_at_utc,
      coalesce(ip.channel, 'call') as interaction_type,
      cr.direction,
      left(
        coalesce(
          nullif(ip.human_summary, ''),
          nullif(cs.transcript_segment, ''),
          ''
        ),
        280
      ) as highlight_text
    from interaction_with_project ip
    left join public.calls_raw cr on cr.interaction_id = ip.interaction_id
    left join lateral (
      select s.transcript_segment
      from public.conversation_spans s
      where s.interaction_id = ip.interaction_id
        and s.is_superseded = false
      order by s.span_index asc
      limit 1
    ) cs on true
    where ip.resolved_project_id is not null
  ),
  sms_with_project as (
    select
      s.*,
      c.id as contact_uuid,
      public.get_contact_anchored_project_id(c.id) as resolved_project_id
    from public.sms_messages s
    inner join public.contacts c on c.phone = s.contact_phone
    where s.sent_at >= v_now - make_interval(hours => v_window_hours)
  ),
  sms_highlights as (
    select
      sp.resolved_project_id as project_id,
      sp.id::text as interaction_id,
      sp.sent_at as event_at_utc,
      'sms'::text as interaction_type,
      sp.direction,
      left(coalesce(nullif(sp.content, ''), ''), 280) as highlight_text
    from sms_with_project sp
    where sp.resolved_project_id is not null
  ),
  combined_highlights as (
    select * from call_highlights
    union all
    select * from sms_highlights
  ),
  ranked_highlights as (
    select
      ch.project_id,
      p.name as project_name,
      ch.interaction_id,
      ch.event_at_utc,
      ch.interaction_type,
      ch.direction,
      ch.highlight_text,
      row_number() over (
        partition by ch.project_id
        order by ch.event_at_utc desc nulls last
      ) as rn
    from combined_highlights ch
    left join public.projects p on p.id = ch.project_id
  ),
  project_payload as (
    select
      h.project_id,
      coalesce(max(h.project_name), h.project_id::text) as project_name,
      max(h.event_at_utc) as last_event_at,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'interaction_id', h.interaction_id,
            'event_at_utc', h.event_at_utc,
            'interaction_type', h.interaction_type,
            'direction', h.direction,
            'highlight_text', h.highlight_text
          )
          order by h.event_at_utc desc nulls last
        ) filter (where h.rn <= v_highlights_per_project),
        '[]'::jsonb
      ) as highlights
    from ranked_highlights h
    where h.rn <= v_highlights_per_project
    group by h.project_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'project_id', pp.project_id,
        'project_name', pp.project_name,
        'last_event_at', pp.last_event_at,
        'highlights', pp.highlights
      )
      order by pp.last_event_at desc nulls last, pp.project_name asc
    ),
    '[]'::jsonb
  )
  into v_project_recent_highlights
  from project_payload pp;

  -- 3) Contact -> project candidate list with single-project marker.
  with contact_base as (
    select
      rc.contact_id,
      rc.contact_name,
      rc.contact_phone,
      rc.last_activity,
      public.get_contact_anchored_project_id(rc.contact_id) as anchored_project_id
    from public.redline_contacts rc
    order by rc.last_activity desc nulls last, rc.contact_name asc
    limit v_contacts_limit
  ), interaction_candidates as (
    select
      i.contact_id,
      (cp.elem->>'id')::uuid as project_id,
      max(cp.elem->>'name') as candidate_project_name,
      max(coalesce((cp.elem->>'confidence')::numeric, 0)) as candidate_confidence,
      max(i.event_at_utc) as last_candidate_seen_at,
      count(*)::int as candidate_mentions
    from public.interactions i
    join contact_base cb
      on cb.contact_id = i.contact_id
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(i.candidate_projects) = 'array' then i.candidate_projects
        else '[]'::jsonb
      end
    ) cp(elem)
    where coalesce(cp.elem->>'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      and i.event_at_utc >= v_now - interval '30 days'
    group by i.contact_id, (cp.elem->>'id')::uuid
  ), project_contact_candidates as (
    select
      cb.contact_id,
      pc.project_id,
      p.name as candidate_project_name,
      1.0::numeric as candidate_confidence,
      null::timestamptz as last_candidate_seen_at,
      1::int as candidate_mentions
    from contact_base cb
    join public.project_contacts pc
      on pc.contact_id = cb.contact_id
     and pc.is_active = true
    left join public.projects p
      on p.id = pc.project_id
  ), anchored_candidates as (
    select
      cb.contact_id,
      cb.anchored_project_id as project_id,
      p.name as candidate_project_name,
      1.0::numeric as candidate_confidence,
      null::timestamptz as last_candidate_seen_at,
      1::int as candidate_mentions
    from contact_base cb
    left join public.projects p
      on p.id = cb.anchored_project_id
    where cb.anchored_project_id is not null
  ), combined_candidates as (
    select
      ic.contact_id,
      ic.project_id,
      coalesce(ic.candidate_project_name, p.name) as candidate_project_name,
      ic.candidate_confidence,
      ic.last_candidate_seen_at,
      ic.candidate_mentions,
      false as source_anchored_contact,
      false as source_project_contacts,
      true as source_interaction_candidates,
      50 as source_rank
    from interaction_candidates ic
    left join public.projects p
      on p.id = ic.project_id

    union all

    select
      pc.contact_id,
      pc.project_id,
      coalesce(pc.candidate_project_name, p.name) as candidate_project_name,
      pc.candidate_confidence,
      pc.last_candidate_seen_at,
      pc.candidate_mentions,
      false as source_anchored_contact,
      true as source_project_contacts,
      false as source_interaction_candidates,
      80 as source_rank
    from project_contact_candidates pc
    left join public.projects p
      on p.id = pc.project_id

    union all

    select
      ac.contact_id,
      ac.project_id,
      coalesce(ac.candidate_project_name, p.name) as candidate_project_name,
      ac.candidate_confidence,
      ac.last_candidate_seen_at,
      ac.candidate_mentions,
      true as source_anchored_contact,
      false as source_project_contacts,
      false as source_interaction_candidates,
      100 as source_rank
    from anchored_candidates ac
    left join public.projects p
      on p.id = ac.project_id
  ), dedup_candidates as (
    select
      cc.contact_id,
      cc.project_id,
      max(cc.candidate_project_name) as candidate_project_name,
      max(cc.candidate_confidence) as candidate_confidence,
      max(cc.last_candidate_seen_at) as last_candidate_seen_at,
      sum(cc.candidate_mentions)::int as candidate_mentions,
      bool_or(cc.source_anchored_contact) as source_anchored_contact,
      bool_or(cc.source_project_contacts) as source_project_contacts,
      bool_or(cc.source_interaction_candidates) as source_interaction_candidates,
      max(cc.source_rank) as source_rank
    from combined_candidates cc
    where cc.project_id is not null
    group by cc.contact_id, cc.project_id
  ), ranked_candidates as (
    select
      dc.*,
      row_number() over (
        partition by dc.contact_id
        order by dc.source_rank desc, dc.candidate_confidence desc, dc.candidate_project_name asc
      ) as candidate_rank
    from dedup_candidates dc
  ), contact_candidate_payload as (
    select
      rc.contact_id,
      count(*)::int as candidate_count,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'project_id', rc.project_id,
            'project_name', rc.candidate_project_name,
            'confidence', rc.candidate_confidence,
            'candidate_mentions', rc.candidate_mentions,
            'last_candidate_seen_at', rc.last_candidate_seen_at,
            'sources', to_jsonb(array_remove(array[
              case when rc.source_anchored_contact then 'anchored_contact'::text end,
              case when rc.source_project_contacts then 'project_contacts'::text end,
              case when rc.source_interaction_candidates then 'interaction_candidates'::text end
            ], null))
          )
          order by rc.candidate_rank asc
        ) filter (where rc.candidate_rank <= v_candidates_per_contact),
        '[]'::jsonb
      ) as project_candidates
    from ranked_candidates rc
    group by rc.contact_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'contact_id', cb.contact_id,
        'contact_name', cb.contact_name,
        'contact_phone', cb.contact_phone,
        'last_activity', cb.last_activity,
        'anchored_project_id', cb.anchored_project_id,
        'anchored_project_name', ap.name,
        'is_single_project_contact',
          coalesce(ccp.candidate_count, 0) = 1
          or cb.anchored_project_id is not null,
        'candidate_count', coalesce(ccp.candidate_count, 0),
        'project_candidates', coalesce(ccp.project_candidates, '[]'::jsonb)
      )
      order by cb.last_activity desc nulls last, cb.contact_name asc
    ),
    '[]'::jsonb
  )
  into v_contact_project_candidates
  from contact_base cb
  left join contact_candidate_payload ccp
    on ccp.contact_id = cb.contact_id
  left join public.projects ap
    on ap.id = cb.anchored_project_id;

  return jsonb_build_object(
    'packet_version', 'assistant_context_v1',
    'generated_at_utc', v_now,
    'window_hours', v_window_hours,
    'projects_roster', v_projects_roster,
    'project_recent_highlights', v_project_recent_highlights,
    'contact_project_candidates', v_contact_project_candidates
  );
end;
$$;

comment on function public.assistant_context_v1(integer, integer, integer, integer, integer) is
  'Canonical assistant context surface: projects roster, recent highlights from calls + SMS (two-path), and contact-project candidate mapping with single-project marker.';

commit;
