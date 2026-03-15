-- BuilderTrend-equivalent reporting substrate for CAMBER.
-- Depends on the adjacent job-costing backbone in
-- 20260314004000_create_job_costing_views.sql rather than redefining it.

create extension if not exists pgcrypto;

alter table public.projects
  add column if not exists contract_type text default 'Fixed Price',
  add column if not exists contract_price numeric(12,2) default 0,
  add column if not exists planned_start date,
  add column if not exists planned_end date,
  add column if not exists actual_start date;

comment on column public.projects.contract_type is
  'Commercial posture for BuilderTrend-style reporting (for example Fixed Price or Cost Plus).';
comment on column public.projects.contract_price is
  'Primary contract value for BuilderTrend-style WIP, profitability, and cashflow reporting.';
comment on column public.projects.planned_start is
  'Planned field start date used by BuilderTrend-equivalent schedule views.';
comment on column public.projects.planned_end is
  'Planned completion date used by BuilderTrend-equivalent schedule views.';
comment on column public.projects.actual_start is
  'Actual field start date used for duration variance and schedule progress reporting.';

update public.projects
set
  contract_type = coalesce(contract_type, 'Fixed Price'),
  contract_price = coalesce(nullif(contract_price, 0), contract_value, 0),
  planned_start = coalesce(planned_start, start_date),
  planned_end = coalesce(planned_end, target_completion_date)
where
  contract_type is null
  or contract_price is null
  or contract_price = 0
  or planned_start is null
  or planned_end is null;

create table if not exists public.client_invoices (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  invoice_number text,
  invoice_status text not null default 'draft',
  invoice_date date,
  due_date date,
  paid_date date,
  billed_amount numeric(12,2) not null default 0,
  retainage_amount numeric(12,2) not null default 0,
  paid_amount numeric(12,2) not null default 0,
  source text default 'manual',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id, invoice_number)
);

create index if not exists idx_client_invoices_project_id on public.client_invoices(project_id);
create index if not exists idx_client_invoices_status on public.client_invoices(invoice_status);
create index if not exists idx_client_invoices_due_date on public.client_invoices(due_date);

drop trigger if exists trg_client_invoices_updated_at on public.client_invoices;
create trigger trg_client_invoices_updated_at
before update on public.client_invoices
for each row execute function public.tg_set_updated_at();

comment on table public.client_invoices is
  'Client-facing invoice ledger for BuilderTrend-equivalent invoicing and cashflow reporting.';

create table if not exists public.change_orders (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  change_order_number text,
  title text not null,
  status text not null default 'draft',
  requested_date date,
  approved_date date,
  owner_price_delta numeric(12,2) not null default 0,
  vendor_cost_delta numeric(12,2) not null default 0,
  scope_summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id, change_order_number)
);

create index if not exists idx_change_orders_project_id on public.change_orders(project_id);
create index if not exists idx_change_orders_status on public.change_orders(status);
create index if not exists idx_change_orders_approved_date on public.change_orders(approved_date);

drop trigger if exists trg_change_orders_updated_at on public.change_orders;
create trigger trg_change_orders_updated_at
before update on public.change_orders
for each row execute function public.tg_set_updated_at();

comment on table public.change_orders is
  'Owner-facing change order register for BuilderTrend-equivalent change management and margin reporting.';

create or replace view public.v_bt_project_intelligence as
with call_rollup as (
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
  p.id as project_id,
  p.name as project_name,
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
from public.projects p
left join call_rollup cr
  on cr.project_id = p.id
left join silent_contacts sc
  on sc.project_id = p.id
left join vendor_claim_signals vs
  on vs.project_id = p.id;

comment on view public.v_bt_project_intelligence is
  'CAMBER enrichment layer for BuilderTrend-style reports: recent call volume, silent contacts, last call, and vendor sentiment.';

create or replace view public.v_bt_budget_rollup as
with base as (
  select
    p.id as project_id,
    coalesce(jcs.budget_line_count, 0)::bigint as budget_line_count,
    coalesce(jcs.budget_total, 0)::numeric(14,2) as original_budget,
    0::numeric(14,2) as approved_budget_changes,
    coalesce(jcs.budget_total, 0)::numeric(14,2) as revised_budget,
    coalesce(jcs.actual_total, 0)::numeric(14,2) as actual_cost,
    greatest(
      coalesce(jcs.actual_total, 0),
      coalesce(fe.total_committed, 0)
    )::numeric(14,2) as committed_cost,
    greatest(
      coalesce(jcs.budget_total, 0),
      coalesce(jcs.actual_total, 0),
      coalesce(fe.total_committed, 0),
      coalesce(fe.total_committed, 0) + coalesce(fe.total_pending, 0)
    )::numeric(14,2) as projected_cost
  from public.projects p
  left join public.v_job_costing_summary jcs
    on jcs.project_id = p.id
  left join public.v_financial_exposure fe
    on fe.project_id = p.id
)
select
  project_id,
  budget_line_count,
  original_budget,
  approved_budget_changes,
  revised_budget,
  projected_cost,
  committed_cost,
  actual_cost,
  greatest(projected_cost - actual_cost, 0)::numeric(14,2) as cost_to_complete
from base;

comment on view public.v_bt_budget_rollup is
  'Project-level budget rollup built on the local job-costing backbone plus CAMBER financial exposure signals.';

create or replace view public.v_bt_change_order_rollup as
select
  co.project_id,
  count(*)::bigint as total_change_orders,
  count(*) filter (where co.status in ('pending', 'priced', 'submitted'))::bigint as pending_change_orders,
  count(*) filter (where co.status = 'approved')::bigint as approved_change_orders,
  count(*) filter (where co.status in ('rejected', 'void'))::bigint as rejected_change_orders,
  coalesce(sum(co.owner_price_delta) filter (where co.status = 'approved'), 0)::numeric(12,2) as approved_owner_change_revenue,
  coalesce(sum(co.vendor_cost_delta) filter (where co.status = 'approved'), 0)::numeric(12,2) as approved_vendor_change_cost,
  coalesce(sum(co.owner_price_delta - co.vendor_cost_delta) filter (where co.status = 'approved'), 0)::numeric(12,2) as approved_change_margin,
  max(coalesce(co.approved_date, co.requested_date)) as last_change_order_at
from public.change_orders co
group by co.project_id;

comment on view public.v_bt_change_order_rollup is
  'Project-level change order totals for BuilderTrend-style contract revision and margin reporting.';

create or replace view public.v_bt_invoice_rollup as
select
  ci.project_id,
  count(*)::bigint as total_invoices,
  count(*) filter (
    where ci.invoice_status not in ('paid', 'void')
  )::bigint as open_invoices,
  coalesce(sum(ci.billed_amount), 0)::numeric(12,2) as total_billed,
  coalesce(sum(ci.retainage_amount), 0)::numeric(12,2) as total_retainage,
  coalesce(sum(ci.paid_amount), 0)::numeric(12,2) as total_paid,
  coalesce(sum(greatest(ci.billed_amount - ci.retainage_amount - ci.paid_amount, 0)), 0)::numeric(12,2) as total_outstanding,
  coalesce(sum(greatest(ci.billed_amount - ci.retainage_amount - ci.paid_amount, 0)) filter (
    where ci.due_date < current_date
      and ci.invoice_status not in ('paid', 'void')
  ), 0)::numeric(12,2) as overdue_amount,
  count(*) filter (
    where ci.due_date < current_date
      and ci.invoice_status not in ('paid', 'void')
  )::bigint as overdue_invoices,
  max(ci.invoice_date) as last_invoice_date,
  min(ci.due_date) filter (
    where ci.invoice_status not in ('paid', 'void')
      and ci.paid_amount < (ci.billed_amount - ci.retainage_amount)
  ) as next_due_date
from public.client_invoices ci
group by ci.project_id;

comment on view public.v_bt_invoice_rollup is
  'Project-level client invoice rollup for BuilderTrend-style invoicing and cashflow reporting.';

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
  on prs.project_id = p.id;

comment on view public.v_bt_project_report_base is
  'Shared project financial and intelligence spine used by BuilderTrend-style report views.';

create or replace view public.v_wip_report as
with base as (
  select
    rb.*,
    (rb.contract_price + rb.approved_owner_change_revenue)::numeric(12,2) as revised_contract_value,
    greatest(rb.projected_cost, rb.revised_budget, rb.actual_cost)::numeric(14,2) as estimated_total_cost
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  client_name,
  project_status,
  contract_type,
  contract_price as original_contract_value,
  approved_owner_change_revenue as approved_change_revenue,
  revised_contract_value,
  original_budget,
  approved_budget_changes,
  revised_budget,
  actual_cost as cost_to_date,
  estimated_total_cost,
  case
    when estimated_total_cost > 0
      then round((actual_cost / estimated_total_cost) * 100, 1)
    else null
  end as cost_complete_pct,
  round(
    revised_contract_value * actual_cost / nullif(estimated_total_cost, 0),
    2
  ) as earned_revenue,
  total_billed as billed_to_date,
  round(
    total_billed
    - (revised_contract_value * actual_cost / nullif(estimated_total_cost, 0)),
    2
  ) as over_under_billing,
  round(revised_contract_value - total_billed, 2) as backlog_revenue,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from base;

comment on view public.v_wip_report is
  'BuilderTrend-style work-in-progress report with CAMBER call and vendor intelligence columns.';

create or replace view public.v_budget_vs_projected as
with receipt_lines as (
  select
    v.project_id,
    v.canonical_cost_code as cost_code,
    max(v.cost_code_name) as cost_code_name,
    max(v.division) as division,
    sum(coalesce(v.actual_total, 0))::numeric(14,2) as actual_cost,
    sum(coalesce(v.pending_total, 0))::numeric(14,2) as pending_cost
  from public.v_job_costing_by_project v
  where v.canonical_cost_code is not null
  group by v.project_id, v.canonical_cost_code
)
select
  jb.project_id,
  p.name as project_name,
  jb.cost_code,
  coalesce(cct.name, rl.cost_code_name) as cost_code_name,
  coalesce(cct.parent_category_code, jb.cost_code)::text as phase_code,
  cp.short_name as phase_name,
  coalesce(cct.division, rl.division) as division,
  jb.source as budget_source,
  jb.budget_amount::numeric(14,2) as original_budget,
  0::numeric(14,2) as approved_changes,
  jb.budget_amount::numeric(14,2) as revised_budget,
  coalesce(rl.actual_cost, 0)::numeric(14,2) as actual_cost,
  (coalesce(rl.actual_cost, 0) + coalesce(rl.pending_cost, 0))::numeric(14,2) as committed_cost,
  greatest(
    jb.budget_amount,
    coalesce(rl.actual_cost, 0) + coalesce(rl.pending_cost, 0)
  )::numeric(14,2) as projected_cost,
  (
    jb.budget_amount
    - greatest(
      jb.budget_amount,
      coalesce(rl.actual_cost, 0) + coalesce(rl.pending_cost, 0)
    )
  )::numeric(14,2) as variance_to_budget,
  greatest(
    greatest(
      jb.budget_amount,
      coalesce(rl.actual_cost, 0) + coalesce(rl.pending_cost, 0)
    ) - coalesce(rl.actual_cost, 0),
    0
  )::numeric(14,2) as cost_to_complete,
  base.call_volume_14d,
  base.silent_contacts,
  base.last_call_date,
  base.vendor_sentiment
from public.job_budgets jb
join public.projects p
  on p.id = jb.project_id
left join receipt_lines rl
  on rl.project_id = jb.project_id
 and rl.cost_code = jb.cost_code
left join public.cost_code_taxonomy cct
  on cct.code = jb.cost_code
left join public.construction_phases cp
  on cp.code = coalesce(cct.parent_category_code, jb.cost_code)::bpchar
left join public.v_bt_project_report_base base
  on base.project_id = jb.project_id;

comment on view public.v_budget_vs_projected is
  'BuilderTrend-style budget-vs-projected report by budgeted cost code, using the local receipt-backed job-costing backbone.';

create or replace view public.v_profitability_report as
with base as (
  select
    rb.*,
    (rb.contract_price + rb.approved_owner_change_revenue)::numeric(12,2) as revised_contract_value,
    greatest(rb.projected_cost, rb.revised_budget, rb.actual_cost)::numeric(14,2) as estimated_total_cost
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  client_name,
  project_status,
  revised_contract_value,
  estimated_total_cost,
  actual_cost as actual_cost_to_date,
  total_paid as cash_received_to_date,
  total_billed as billed_to_date,
  round(revised_contract_value - estimated_total_cost, 2) as projected_gross_profit,
  case
    when revised_contract_value > 0
      then round(((revised_contract_value - estimated_total_cost) / revised_contract_value) * 100, 1)
    else null
  end as projected_gross_margin_pct,
  round(total_paid - actual_cost, 2) as realized_gross_profit,
  case
    when total_paid > 0
      then round(((total_paid - actual_cost) / total_paid) * 100, 1)
    else null
  end as realized_margin_pct,
  approved_change_margin,
  risk_score,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from base;

comment on view public.v_profitability_report is
  'BuilderTrend-style profitability report with CAMBER risk and communication context.';

create or replace view public.v_invoicing_report as
with base as (
  select
    rb.*,
    (rb.contract_price + rb.approved_owner_change_revenue)::numeric(12,2) as revised_contract_value
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  client_name,
  total_invoices,
  open_invoices,
  total_billed,
  total_retainage,
  total_paid,
  total_outstanding,
  overdue_invoices,
  overdue_amount,
  last_invoice_date,
  next_due_date,
  inferred_total_invoiced,
  inferred_total_pending,
  oldest_unpaid_days,
  case
    when revised_contract_value > 0
      then round((total_billed / revised_contract_value) * 100, 1)
    else null
  end as billing_pct_of_revised_contract,
  case
    when total_billed > 0
      then round((total_paid / total_billed) * 100, 1)
    else null
  end as collection_pct,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from base;

comment on view public.v_invoicing_report is
  'BuilderTrend-style invoicing report with CAMBER signal columns for communication silence and vendor sentiment.';

create or replace view public.v_cashflow_report as
with base as (
  select
    rb.*,
    (rb.contract_price + rb.approved_owner_change_revenue)::numeric(12,2) as revised_contract_value
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  client_name,
  revised_contract_value,
  total_billed as billings_to_date,
  total_paid as cash_received,
  actual_cost as cash_spent_actual,
  committed_cost as vendor_commitments,
  greatest(committed_cost - actual_cost, 0)::numeric(14,2) as open_commitments,
  total_outstanding as accounts_receivable,
  overdue_amount as overdue_receivables,
  round(total_paid - actual_cost, 2) as net_cash_position,
  round(revised_contract_value - total_billed, 2) as unbilled_revenue,
  inferred_total_pending as pending_financial_signals,
  oldest_unpaid_days,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from base;

comment on view public.v_cashflow_report is
  'BuilderTrend-style cashflow report with CAMBER communication and vendor intelligence fields.';

create or replace view public.v_schedule_progress as
with calc as (
  select
    rb.*,
    case
      when rb.planned_start is not null
       and rb.planned_end is not null
       and rb.planned_end >= rb.planned_start
        then (rb.planned_end - rb.planned_start + 1)
      else null
    end as planned_duration_days,
    case
      when rb.planned_start is not null
        then greatest(current_date - rb.planned_start, 0)
      else null
    end as planned_elapsed_days,
    case
      when coalesce(rb.actual_start, rb.planned_start) is not null
        then greatest(current_date - coalesce(rb.actual_start, rb.planned_start), 0)
      else null
    end as actual_elapsed_days
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  project_status,
  phase_code,
  phase_name,
  next_milestone,
  planned_start,
  planned_end,
  actual_start,
  planned_duration_days,
  actual_elapsed_days,
  case
    when phase_sequence is not null
      then round((phase_sequence::numeric / 9) * 100, 1)
    else null
  end as phase_progress_pct,
  case
    when planned_duration_days > 0
      then round(least(100, greatest(0, (actual_elapsed_days::numeric / planned_duration_days) * 100)), 1)
    else null
  end as schedule_progress_pct,
  case
    when planned_duration_days > 0 and planned_end is not null
      then planned_end + greatest(actual_elapsed_days - least(planned_elapsed_days, planned_duration_days), 0)
    else null
  end as projected_finish_date,
  case
    when planned_start is null or planned_end is null then 'unscheduled'
    when planned_end < current_date then 'late'
    when risk_score >= 8 or open_loop_count >= 3 then 'at_risk'
    else 'on_track'
  end as schedule_status,
  risk_score,
  open_loop_count,
  striking_signal_count,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from calc;

comment on view public.v_schedule_progress is
  'BuilderTrend-style schedule progress report using CAMBER phases, risk signals, and communication cadence.';

create or replace view public.v_duration_variance as
with calc as (
  select
    rb.*,
    case
      when rb.planned_start is not null
       and rb.planned_end is not null
       and rb.planned_end >= rb.planned_start
        then (rb.planned_end - rb.planned_start + 1)
      else null
    end as planned_duration_days,
    case
      when rb.planned_start is not null
        then greatest(current_date - rb.planned_start, 0)
      else null
    end as planned_elapsed_days,
    case
      when coalesce(rb.actual_start, rb.planned_start) is not null
        then greatest(current_date - coalesce(rb.actual_start, rb.planned_start), 0)
      else null
    end as actual_elapsed_days
  from public.v_bt_project_report_base rb
)
select
  project_id,
  project_name,
  phase_code,
  phase_name,
  planned_start,
  planned_end,
  actual_start,
  planned_duration_days,
  planned_elapsed_days,
  actual_elapsed_days,
  case
    when planned_start is not null and actual_start is not null
      then actual_start - planned_start
    else null
  end as start_variance_days,
  case
    when planned_elapsed_days is not null and actual_elapsed_days is not null and planned_duration_days is not null
      then actual_elapsed_days - least(planned_elapsed_days, planned_duration_days)
    else null
  end as duration_variance_days,
  case
    when planned_duration_days > 0 and planned_end is not null
      then planned_end + greatest(actual_elapsed_days - least(planned_elapsed_days, planned_duration_days), 0)
    else null
  end as projected_finish_date,
  case
    when planned_duration_days > 0 and planned_end is not null
      then greatest(actual_elapsed_days - least(planned_elapsed_days, planned_duration_days), 0)
    else null
  end as finish_variance_days,
  risk_score,
  open_loop_count,
  call_volume_14d,
  silent_contacts,
  last_call_date,
  vendor_sentiment
from calc;

comment on view public.v_duration_variance is
  'BuilderTrend-style duration variance report using planned versus actual elapsed days plus CAMBER signal columns.';

create or replace view public.v_daily_activity as
with daily_rollup as (
  select
    pat.project_id,
    pat.project_name,
    pat.event_timestamp::date as activity_date,
    count(*) filter (where pat.event_type = 'call')::bigint as call_events,
    count(*) filter (where pat.event_type = 'sms')::bigint as sms_events,
    count(*) filter (where pat.event_type = 'claim')::bigint as claim_events,
    count(*) filter (where pat.event_type = 'task')::bigint as task_events,
    count(*) filter (where pat.event_type = 'timeline_event')::bigint as timeline_events,
    max(pat.event_timestamp) as last_activity_at
  from public.v_project_activity_timeline pat
  where pat.project_id is not null
    and pat.event_timestamp >= current_date - interval '30 days'
  group by pat.project_id, pat.project_name, pat.event_timestamp::date
)
select
  dr.project_id,
  dr.project_name,
  dr.activity_date,
  dr.call_events,
  dr.sms_events,
  dr.claim_events,
  dr.task_events,
  dr.timeline_events,
  (dr.call_events + dr.sms_events + dr.claim_events + dr.task_events + dr.timeline_events)::bigint as total_events,
  dr.last_activity_at,
  base.call_volume_14d,
  base.silent_contacts,
  base.last_call_date,
  base.vendor_sentiment
from daily_rollup dr
left join public.v_bt_project_report_base base
  on base.project_id = dr.project_id;

comment on view public.v_daily_activity is
  'BuilderTrend-style daily project activity rollup from CAMBER timeline surfaces with communication enrichment columns.';

create or replace view public.v_change_order_register as
select
  co.id as change_order_id,
  co.project_id,
  p.name as project_name,
  co.change_order_number,
  co.title,
  co.status,
  co.requested_date,
  co.approved_date,
  co.owner_price_delta,
  co.vendor_cost_delta,
  (co.owner_price_delta - co.vendor_cost_delta)::numeric(12,2) as gross_margin_delta,
  base.call_volume_14d,
  base.silent_contacts,
  base.last_call_date,
  base.vendor_sentiment
from public.change_orders co
join public.projects p
  on p.id = co.project_id
left join public.v_bt_project_report_base base
  on base.project_id = co.project_id;

comment on view public.v_change_order_register is
  'Project-level change order register. Serves as the change-order-side BuilderTrend equivalent while CAMBER labor hours remain a placeholder.';

create or replace view public.v_hours_report_placeholder as
select
  p.id as project_id,
  p.name as project_name,
  null::numeric(12,2) as planned_labor_hours,
  null::numeric(12,2) as actual_labor_hours,
  null::numeric(12,2) as labor_variance_hours,
  'Placeholder only: CAMBER does not yet have a labor-hours SSOT or timecard feed.'::text as note
from public.projects p;

comment on view public.v_hours_report_placeholder is
  'Explicit placeholder for future BuilderTrend-style labor-hours reporting once CAMBER has a timecard or payroll substrate.';
