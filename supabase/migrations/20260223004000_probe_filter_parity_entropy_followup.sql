-- Follow-up reconcile migration (no-conflict):
-- Apply only remaining probe/shadow/test exclusions for parity + entropy KPI.
-- Intentionally does NOT rewrite v_metrics_phase1_summary, because that surface
-- is already covered by 20260222171250 in production.

begin;
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
