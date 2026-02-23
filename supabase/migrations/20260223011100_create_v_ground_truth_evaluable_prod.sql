-- create_v_ground_truth_evaluable_prod
-- Policy: exclude known non-prod PIPELINE_NULL rows from GT denominator.

create or replace view public.v_ground_truth_evaluable_non_prod_exclusions as
with base as (
  select
    v.*,
    i.is_shadow
  from public.v_ground_truth_evaluable v
  left join public.interactions i
    on i.interaction_id = v.call_id
),
flagged as (
  select
    b.*,
    (coalesce(b.is_shadow, false) or b.call_id like 'cll_SHADOW_%') as is_shadow_fixture,
    (coalesce(b.contact_name, '') ~* '(sittler|madison|athens|bishop)') as is_blocked_contact
  from base b
)
select
  label_id,
  call_id,
  contact_name,
  agreement,
  event_at_utc,
  gt_project_id,
  pipeline_project_id,
  is_shadow_fixture,
  is_blocked_contact,
  case
    when is_shadow_fixture then 'shadow_fixture'
    when is_blocked_contact then 'blocked_contact'
    else null
  end as exclusion_reason
from flagged
where agreement = 'PIPELINE_NULL'
  and (is_shadow_fixture or is_blocked_contact);

create or replace view public.v_ground_truth_evaluable_prod as
select
  v.*
from public.v_ground_truth_evaluable v
where not exists (
  select 1
  from public.v_ground_truth_evaluable_non_prod_exclusions x
  where x.label_id = v.label_id
);

grant select on public.v_ground_truth_evaluable_non_prod_exclusions to anon, authenticated, service_role;
grant select on public.v_ground_truth_evaluable_prod to anon, authenticated, service_role;

