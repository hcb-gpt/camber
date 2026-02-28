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

  -- 2) Per-project recent highlights from SSOT timeline surfaces.
  with highlights as (
    select
      i.project_id,
      p.name as project_name,
      rt.interaction_id::text as interaction_id,
      rt.event_at_utc,
      rt.interaction_type,
      rt.direction,
      left(
        coalesce(
          nullif(rt.summary, ''),
          nullif(rt.claim_text, ''),
          nullif(rt.span_text, ''),
          nullif(rt.transcript_segment, ''),
          nullif(i.human_summary, ''),
          ''
        ),
        280
      ) as highlight_text,
      row_number() over (
        partition by i.project_id
        order by rt.event_at_utc desc nulls last
      ) as rn
    from public.redline_thread rt
    join public.interactions i
      on i.id = rt.interaction_id
    left join public.projects p
      on p.id = i.project_id
    where i.project_id is not null
      and rt.event_at_utc >= v_now - make_interval(hours => v_window_hours)
  ), project_payload as (
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
    from highlights h
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
  'Canonical assistant context surface: projects roster, 24h project highlights from redline_thread/interactions, and contact-project candidate mapping with single-project marker.';

grant execute on function public.assistant_context_v1(integer, integer, integer, integer, integer)
  to authenticated, anon, service_role;

create or replace view public.v_assistant_context_v1 as
select public.assistant_context_v1() as payload;

grant select on public.v_assistant_context_v1 to authenticated, anon, service_role;

comment on view public.v_assistant_context_v1 is
  'Wrapper view for assistant_context_v1() to support PostgREST read patterns.';

commit;
