begin;

create or replace view public.v_bt_project_intelligence as
with scoped_projects as (
  select
    p.id,
    p.name
  from public.projects p
  where p.project_kind = 'client'
    and p.status in ('active', 'warranty', 'estimating')
),
call_rollup as (
  select
    i.project_id,
    count(*) filter (
      where coalesce(cr.event_at_utc, cr.ingested_at_utc) >= now() - interval '14 days'
    )::bigint as call_volume_14d,
    max(coalesce(cr.event_at_utc, cr.ingested_at_utc)) as last_call_date
  from public.calls_raw cr
  join public.interactions i
    on i.interaction_id = cr.interaction_id
  where i.project_id is not null
  group by i.project_id
),
silent_contacts as (
  select
    pc.project_id,
    count(*) filter (
      where pc.is_active = true
        and (
          cas.last_call_date is null
          or cas.last_call_date < now() - interval '14 days'
        )
    )::bigint as silent_contacts
  from public.project_contacts pc
  left join public.v_contact_activity_summary cas
    on cas.contact_id = pc.contact_id
  group by pc.project_id
),
vendor_claim_signals as (
  select
    pc.project_id,
    count(*) filter (
      where jc.claim_type in ('commitment', 'fact', 'update', 'decision')
    )::bigint as positive_vendor_signals_30d,
    count(*) filter (
      where jc.claim_type in ('blocker', 'concern', 'question', 'deadline')
    )::bigint as negative_vendor_signals_30d
  from public.project_contacts pc
  join public.contacts c
    on c.id = pc.contact_id
  left join public.journal_claims jc
    on jc.project_id = pc.project_id
   and jc.active = true
   and jc.created_at >= now() - interval '30 days'
   and (
     jc.speaker_contact_id = pc.contact_id
     or jc.reported_by_contact_id = pc.contact_id
   )
  where pc.is_active = true
    and c.contact_type in ('vendor', 'subcontractor', 'site_supervisor')
  group by pc.project_id
)
select
  sp.id as project_id,
  sp.name as project_name,
  coalesce(cr.call_volume_14d, 0)::bigint as call_volume_14d,
  coalesce(sc.silent_contacts, 0)::bigint as silent_contacts,
  cr.last_call_date,
  case
    when coalesce(vs.positive_vendor_signals_30d, 0) = 0
      and coalesce(vs.negative_vendor_signals_30d, 0) = 0
      then 'unknown'
    when coalesce(vs.negative_vendor_signals_30d, 0) > coalesce(vs.positive_vendor_signals_30d, 0)
      then 'negative'
    when coalesce(vs.positive_vendor_signals_30d, 0) > coalesce(vs.negative_vendor_signals_30d, 0)
      then 'positive'
    else 'mixed'
  end as vendor_sentiment,
  coalesce(vs.positive_vendor_signals_30d, 0)::bigint as vendor_positive_signals_30d,
  coalesce(vs.negative_vendor_signals_30d, 0)::bigint as vendor_negative_signals_30d
from scoped_projects sp
left join call_rollup cr
  on cr.project_id = sp.id
left join silent_contacts sc
  on sc.project_id = sp.id
left join vendor_claim_signals vs
  on vs.project_id = sp.id;

comment on view public.v_bt_project_intelligence is
  'CAMBER enrichment layer for BuilderTrend-style reports scoped to active/warranty/estimating client projects.';

create or replace view public.v_bt_project_report_base as
select
  p.id as project_id,
  p.name as project_name,
  p.client_name,
  p.status as project_status,
  coalesce(p.contract_type, 'Fixed Price') as contract_type,
  coalesce(nullif(p.contract_price, 0), p.contract_value, 0)::numeric(12,2) as contract_price,
  p.contract_value::numeric(12,2) as legacy_contract_value,
  p.planned_start,
  p.planned_end,
  p.actual_start,
  vpp.phase_code,
  vpp.phase_name,
  vpp.phase_sequence,
  vpp.next_milestone,
  coalesce(br.original_budget, 0)::numeric(14,2) as original_budget,
  coalesce(br.approved_budget_changes, 0)::numeric(14,2) as approved_budget_changes,
  coalesce(br.revised_budget, 0)::numeric(14,2) as revised_budget,
  coalesce(br.projected_cost, 0)::numeric(14,2) as projected_cost,
  coalesce(br.committed_cost, 0)::numeric(14,2) as committed_cost,
  coalesce(br.actual_cost, 0)::numeric(14,2) as actual_cost,
  coalesce(br.cost_to_complete, 0)::numeric(14,2) as cost_to_complete,
  coalesce(cor.total_change_orders, 0)::bigint as total_change_orders,
  coalesce(cor.pending_change_orders, 0)::bigint as pending_change_orders,
  coalesce(cor.approved_change_orders, 0)::bigint as approved_change_orders,
  coalesce(cor.rejected_change_orders, 0)::bigint as rejected_change_orders,
  coalesce(cor.approved_owner_change_revenue, 0)::numeric(12,2) as approved_owner_change_revenue,
  coalesce(cor.approved_vendor_change_cost, 0)::numeric(12,2) as approved_vendor_change_cost,
  coalesce(cor.approved_change_margin, 0)::numeric(12,2) as approved_change_margin,
  cor.last_change_order_at,
  coalesce(ir.total_invoices, 0)::bigint as total_invoices,
  coalesce(ir.open_invoices, 0)::bigint as open_invoices,
  coalesce(ir.total_billed, 0)::numeric(12,2) as total_billed,
  coalesce(ir.total_retainage, 0)::numeric(12,2) as total_retainage,
  coalesce(ir.total_paid, 0)::numeric(12,2) as total_paid,
  coalesce(ir.total_outstanding, 0)::numeric(12,2) as total_outstanding,
  coalesce(ir.overdue_amount, 0)::numeric(12,2) as overdue_amount,
  coalesce(ir.overdue_invoices, 0)::bigint as overdue_invoices,
  ir.last_invoice_date,
  ir.next_due_date,
  coalesce(fe.total_committed, 0)::numeric(12,2) as inferred_total_committed,
  coalesce(fe.total_invoiced, 0)::numeric(12,2) as inferred_total_invoiced,
  coalesce(fe.total_pending, 0)::numeric(12,2) as inferred_total_pending,
  coalesce(fe.item_count, 0)::bigint as inferred_financial_item_count,
  coalesce(fe.largest_single_item, 0)::numeric(12,2) as inferred_largest_single_item,
  fe.oldest_unpaid_days,
  coalesce(intel.call_volume_14d, 0)::bigint as call_volume_14d,
  coalesce(intel.silent_contacts, 0)::bigint as silent_contacts,
  intel.last_call_date,
  coalesce(intel.vendor_sentiment, 'unknown') as vendor_sentiment,
  coalesce(prs.risk_score, 0)::bigint as risk_score,
  coalesce(prs.open_loop_count, 0)::bigint as open_loop_count,
  coalesce(prs.striking_signal_count, 0)::bigint as striking_signal_count,
  coalesce(prs.low_confidence_review_count, 0)::bigint as low_confidence_review_count
from public.projects p
left join public.v_projects_with_phase vpp
  on vpp.id = p.id
left join public.v_bt_budget_rollup br
  on br.project_id = p.id
left join public.v_bt_change_order_rollup cor
  on cor.project_id = p.id
left join public.v_bt_invoice_rollup ir
  on ir.project_id = p.id
left join public.v_financial_exposure fe
  on fe.project_id = p.id
left join public.v_bt_project_intelligence intel
  on intel.project_id = p.id
left join public.v_project_risk_scorecard prs
  on prs.project_id = p.id
where p.project_kind = 'client'
  and p.status in ('active', 'warranty', 'estimating');

comment on view public.v_bt_project_report_base is
  'Shared project financial and intelligence spine used by BuilderTrend-style report views, scoped to active/warranty/estimating client projects.';

commit;
