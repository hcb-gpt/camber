-- Probe/shadow exclusion patch for summary + parity + KPI surfaces.
-- Purpose: keep production health metrics free of test/probe contamination.

begin;
create or replace view public.v_metrics_phase1_summary as
with prod_interactions as (
  select
    i.id,
    i.project_id,
    i.needs_review
  from public.interactions i
  where coalesce(i.is_shadow, false) = false
    and coalesce(i.interaction_id, '') !~* '^cll_(DEV|AUTH|SUMMTEST|ITEST|SHADOW|SMS_PROBE|SMOKE_TEST|TEST|PROBE|PROOF|REPLAY)'
),
prod_scheduler_items as (
  select
    si.id,
    si.attribution_status
  from public.scheduler_items si
  left join public.interactions i
    on i.id = si.interaction_id
  where si.interaction_id is null
     or i.id is null
     or (
       coalesce(i.is_shadow, false) = false
       and coalesce(i.interaction_id, '') !~* '^cll_(DEV|AUTH|SUMMTEST|ITEST|SHADOW|SMS_PROBE|SMOKE_TEST|TEST|PROBE|PROOF|REPLAY)'
     )
)
select
  (select count(*) from prod_interactions where project_id is not null) as interactions_attributed,
  (select count(*) from prod_interactions) as interactions_total,
  (select count(*) from prod_interactions where needs_review = true) as interactions_needs_review,
  (select count(*) from prod_scheduler_items where attribution_status = 'resolved') as items_resolved,
  (select count(*) from prod_scheduler_items where attribution_status = 'needs_clarification') as items_needs_clarification,
  (select count(*) from prod_scheduler_items) as items_total,
  (select count(*) from public.project_contacts where is_active = true) as active_assignments,
  (select count(*) from public.correspondent_project_affinity where weight > 0.1) as affinity_edges,
  (select sum(confirmation_count) from public.correspondent_project_affinity) as total_confirmations,
  (select sum(rejection_count) from public.correspondent_project_affinity) as total_rejections;
comment on view public.v_metrics_phase1_summary is
  'Single-query health check for all Phase 1 metrics (excludes probe/shadow/test traffic).';
create or replace view public.v_phone_parity_summary as
with parity as (
  select
    cr.interaction_id,
    cr.other_party_phone as cr_phone,
    cr.owner_phone as cr_owner,
    i.contact_phone as int_phone,
    i.owner_phone as int_owner,
    c.phone as contact_phone,
    i.contact_id,
    cr.pipeline_version,
    cr.event_at_utc,
    case
      when cr.other_party_phone is null then 'FAIL_MISSING_PHONE'
      when i.contact_phone is null and cr.other_party_phone is not null then 'WARN_INT_PHONE_NULL'
      when cr.other_party_phone != coalesce(i.contact_phone, cr.other_party_phone) then 'FAIL_DRIFT'
      else 'PASS'
    end as status
  from public.calls_raw cr
  left join public.interactions i
    on cr.interaction_id = i.interaction_id
  left join public.contacts c
    on i.contact_id = c.id
  where coalesce(cr.is_shadow, false) = false
    and cr.test_batch is null
    and coalesce(cr.interaction_id, '') !~* '^cll_(DEV|AUTH|SUMMTEST|ITEST|SHADOW|SMS_PROBE|SMOKE_TEST|TEST|PROBE|PROOF|REPLAY)'
)
select
  status,
  count(*) as row_count,
  array_agg(interaction_id order by event_at_utc desc) filter (where status != 'PASS') as sample_ids
from parity
group by status;
comment on view public.v_phone_parity_summary is
  'Bulk parity summary over production traffic only (probe/shadow/test rows excluded).';
create or replace view public.kpi_review_reasons_entropy as
select
  'review_queue.reasons' as field_name,
  count(distinct reason_val) as unique_count,
  500 as alert_threshold,
  600 as critical_threshold,
  case
    when count(distinct reason_val) > 600 then 'CRITICAL'
    when count(distinct reason_val) > 500 then 'ALERT'
    else 'OK'
  end as status
from (
  select unnest(i.review_reasons) as reason_val
  from public.interactions i
  where i.review_reasons is not null
    and coalesce(i.is_shadow, false) = false
    and coalesce(i.interaction_id, '') !~* '^cll_(DEV|AUTH|SUMMTEST|ITEST|SHADOW|SMS_PROBE|SMOKE_TEST|TEST|PROBE|PROOF|REPLAY)'
) reasons;
commit;
