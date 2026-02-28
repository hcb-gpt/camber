-- Proof pack for dispatch__assistant_context_data_surfaces_mv__data3__20260228
-- Acceptance checks:
-- 1) Winship project appears in roster
-- 2) assistant_context_v1 has >=3 recent highlight events with interaction_id pointers

with ctx as (
  select public.assistant_context_v1() as payload
)
select
  payload->>'packet_version' as packet_version,
  payload->>'generated_at_utc' as generated_at_utc,
  (payload->>'window_hours')::int as window_hours,
  jsonb_array_length(payload->'projects_roster') as projects_roster_count,
  jsonb_array_length(payload->'project_recent_highlights') as projects_with_highlights,
  coalesce((
    select sum(jsonb_array_length(ph->'highlights'))::int
    from jsonb_array_elements(payload->'project_recent_highlights') ph
  ), 0) as total_highlight_events,
  jsonb_array_length(payload->'contact_project_candidates') as contact_candidate_rows
from ctx;

with ctx as (
  select public.assistant_context_v1() as payload
)
select
  pr->>'id' as project_id,
  pr->>'name' as project_name,
  pr->>'status' as project_status
from ctx,
  lateral jsonb_array_elements(payload->'projects_roster') pr
where lower(pr->>'name') like '%winship%';

with ctx as (
  select public.assistant_context_v1() as payload
)
select
  ph->>'project_id' as project_id,
  ph->>'project_name' as project_name,
  h->>'interaction_id' as interaction_id,
  h->>'event_at_utc' as event_at_utc,
  h->>'interaction_type' as interaction_type,
  h->>'direction' as direction,
  h->>'highlight_text' as highlight_text
from ctx,
  lateral jsonb_array_elements(payload->'project_recent_highlights') ph,
  lateral jsonb_array_elements(ph->'highlights') h
where coalesce(h->>'interaction_id', '') <> ''
order by (h->>'event_at_utc')::timestamptz desc
limit 10;

with ctx as (
  select public.assistant_context_v1() as payload
)
select
  c->>'contact_id' as contact_id,
  c->>'contact_name' as contact_name,
  c->>'is_single_project_contact' as is_single_project_contact,
  c->>'candidate_count' as candidate_count,
  jsonb_array_length(c->'project_candidates') as returned_candidates
from ctx,
  lateral jsonb_array_elements(payload->'contact_project_candidates') c
order by (c->>'last_activity')::timestamptz desc nulls last
limit 10;
