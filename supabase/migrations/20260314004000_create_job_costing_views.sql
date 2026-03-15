begin;

create or replace function public.normalize_job_costing_key(p_text text)
returns text
language sql
immutable
strict
set search_path = public
as $$
  select nullif(regexp_replace(lower(trim(p_text)), '[^a-z0-9]+', '', 'g'), '');
$$;

comment on function public.normalize_job_costing_key(text) is
  'Normalizes project/job labels into a lowercase alphanumeric key for receipt-to-project matching.';

create table if not exists public.job_budgets (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  cost_code character(4) not null references public.cost_code_taxonomy(code),
  budget_amount numeric(14,2) not null check (budget_amount >= 0),
  source text not null default 'manual',
  notes text,
  effective_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_budgets_project_cost_code_key unique (project_id, cost_code)
);

create index if not exists idx_job_budgets_project_id
  on public.job_budgets(project_id);

create index if not exists idx_job_budgets_cost_code
  on public.job_budgets(cost_code);

drop trigger if exists trg_job_budgets_updated_at on public.job_budgets;
create trigger trg_job_budgets_updated_at
before update on public.job_budgets
for each row execute function public.tg_set_updated_at();

comment on table public.job_budgets is
  'Manual per-project budget lines keyed to the canonical cost code taxonomy for BuilderTrend-style job costing.';

create or replace view public.v_receipt_project_job_match as
with eligible_projects as (
  select
    p.id as project_id,
    p.name as project_name,
    p.status as project_status
  from public.projects p
  where p.project_kind = 'client'
    and p.status in ('active', 'warranty', 'estimating')
),
job_names as (
  select distinct
    r.job_name,
    public.normalize_job_costing_key(r.job_name) as job_key
  from public.receipts r
  where public.normalize_job_costing_key(r.job_name) is not null
),
alias_pool as (
  select distinct
    ep.project_id,
    ep.project_name,
    ep.project_status,
    'project_name'::text as alias_source,
    null::text as alias_type,
    null::text as alias_origin,
    ep.project_name as alias_text,
    public.normalize_job_costing_key(ep.project_name) as alias_key,
    0 as source_rank
  from eligible_projects ep

  union all

  select distinct
    ep.project_id,
    ep.project_name,
    ep.project_status,
    case
      when pa.alias_type = 'shorthand' and pa.source = 'manual_review' then 'project_alias_shorthand_manual'
      when pa.alias_type = 'shorthand' then 'project_alias_shorthand'
      when pa.source = 'manual_review' then 'project_alias_manual'
      else 'project_alias'
    end as alias_source,
    pa.alias_type,
    pa.source as alias_origin,
    pa.alias as alias_text,
    public.normalize_job_costing_key(pa.alias) as alias_key,
    case
      when pa.alias_type = 'shorthand' and pa.source = 'manual_review' then 1
      when pa.alias_type = 'shorthand' then 2
      when pa.source = 'manual_review' then 3
      else 4
    end as source_rank
  from eligible_projects ep
  join public.project_aliases pa
    on pa.project_id = ep.project_id
   and pa.active = true
  where public.normalize_job_costing_key(pa.alias) is not null

  union all

  select distinct
    ep.project_id,
    ep.project_name,
    ep.project_status,
    'project_alias_array'::text as alias_source,
    null::text as alias_type,
    'projects.aliases'::text as alias_origin,
    alias_item.alias_text,
    public.normalize_job_costing_key(alias_item.alias_text) as alias_key,
    5 as source_rank
  from eligible_projects ep
  join public.projects p
    on p.id = ep.project_id
  cross join lateral unnest(coalesce(p.aliases, array[]::text[])) as alias_item(alias_text)
  where public.normalize_job_costing_key(alias_item.alias_text) is not null
),
raw_matches as (
  select
    j.job_name,
    j.job_key,
    ap.project_id,
    ap.project_name,
    ap.project_status,
    ap.alias_source,
    ap.alias_type,
    ap.alias_origin,
    ap.alias_text,
    ap.source_rank,
    case
      when ap.alias_text = j.job_name then 0
      when lower(ap.alias_text) = lower(j.job_name) then 1
      else 2
    end as text_match_rank,
    case ap.project_status
      when 'active' then 0
      when 'warranty' then 1
      when 'estimating' then 2
      else 9
    end as status_rank
  from job_names j
  join alias_pool ap
    on ap.alias_key = j.job_key
),
project_level_matches as (
  select distinct on (rm.job_name, rm.project_id)
    rm.job_name,
    rm.job_key,
    rm.project_id,
    rm.project_name,
    rm.project_status,
    rm.alias_source,
    rm.alias_type,
    rm.alias_origin,
    rm.alias_text as matched_alias,
    rm.text_match_rank,
    rm.source_rank,
    rm.status_rank
  from raw_matches rm
  order by
    rm.job_name,
    rm.project_id,
    rm.text_match_rank,
    rm.source_rank,
    length(rm.alias_text),
    rm.alias_text
),
candidate_rollup as (
  select
    plm.job_name,
    count(*) as candidate_count,
    array_agg(plm.project_name order by plm.project_name) as candidate_projects
  from project_level_matches plm
  group by plm.job_name
),
best_job_match as (
  select distinct on (plm.job_name)
    plm.job_name,
    plm.job_key,
    plm.project_id,
    plm.project_name,
    plm.project_status,
    plm.matched_alias,
    plm.alias_source,
    plm.alias_type,
    plm.alias_origin,
    plm.text_match_rank,
    plm.source_rank,
    plm.status_rank
  from project_level_matches plm
  order by
    plm.job_name,
    plm.text_match_rank,
    plm.source_rank,
    plm.status_rank,
    length(plm.matched_alias),
    plm.project_name,
    plm.project_id
)
select
  r.id as receipt_id,
  r.job_name,
  public.normalize_job_costing_key(r.job_name) as job_key,
  bjm.project_id,
  bjm.project_name,
  bjm.project_status,
  bjm.matched_alias,
  bjm.alias_source,
  bjm.alias_type,
  bjm.alias_origin,
  coalesce(cr.candidate_count, 0) as candidate_count,
  coalesce(cr.candidate_projects, array[]::text[]) as candidate_projects,
  case
    when bjm.project_id is null then 'unmatched'
    when coalesce(cr.candidate_count, 0) > 1 then 'ambiguous_resolved'
    else 'matched'
  end as match_status
from public.receipts r
left join best_job_match bjm
  on bjm.job_name = r.job_name
left join candidate_rollup cr
  on cr.job_name = r.job_name;

comment on view public.v_receipt_project_job_match is
  'Resolves each receipt.job_name to the best matching active/warranty/estimating client project, while surfacing ambiguity counts.';

create or replace view public.v_job_costing_by_project as
with matched_receipts as (
  select
    r.id as receipt_id,
    r.job_name,
    r.vendor,
    r.filename,
    r.invoice_or_transaction,
    r.cost_code,
    r.cost_code_name,
    r.cost_code_uncertain,
    r.amount,
    r.tax,
    r.total,
    r.cost_type,
    r.receipt_date,
    r.due_date,
    r.status,
    r.notes,
    rpm.project_id,
    rpm.project_name,
    rpm.project_status,
    rpm.match_status,
    rpm.candidate_count
  from public.receipts r
  join public.v_receipt_project_job_match rpm
    on rpm.receipt_id = r.id
  where rpm.project_id is not null
),
classified_receipts as (
  select
    mr.*,
    cct.code as canonical_cost_code,
    cct.name as canonical_cost_code_name,
    cct.division,
    case
      when mr.cost_code is null then 'uncoded'
      when cct.code is null then 'noncanonical'
      else 'mapped'
    end as cost_code_status,
    coalesce(mr.cost_code, 'UNCODED') as raw_cost_code_bucket
  from matched_receipts mr
  left join public.cost_code_taxonomy cct
    on cct.code = mr.cost_code::bpchar
   and cct.is_assignable = true
)
select
  cr.project_id,
  cr.project_name,
  cr.project_status,
  cr.raw_cost_code_bucket,
  cr.canonical_cost_code,
  cr.cost_code_status,
  coalesce(max(cr.canonical_cost_code_name), nullif(max(cr.cost_code_name), ''), 'Uncoded / Needs Review') as cost_code_name,
  cr.division,
  jb.budget_amount,
  count(*) as receipt_count,
  sum(cr.total) as actual_total,
  sum(coalesce(cr.amount, cr.total - coalesce(cr.tax, 0), cr.total)) as pre_tax_total,
  sum(coalesce(cr.tax, 0)) as tax_total,
  sum(case when lower(coalesce(cr.status, '')) = 'pending' then cr.total else 0 end) as pending_total,
  min(cr.receipt_date) as first_receipt_date,
  max(cr.receipt_date) as last_receipt_date,
  count(*) filter (where cr.cost_code_uncertain is true) as uncertain_code_receipt_count,
  array_agg(distinct cr.cost_type order by cr.cost_type) filter (where cr.cost_type is not null) as cost_types,
  array_agg(distinct cr.vendor order by cr.vendor) filter (where cr.vendor is not null) as vendors,
  array_agg(distinct cr.job_name order by cr.job_name) as matched_job_names,
  coalesce(jb.budget_amount, 0) - sum(cr.total) as budget_remaining,
  sum(cr.total) - coalesce(jb.budget_amount, 0) as budget_variance
from classified_receipts cr
left join public.job_budgets jb
  on jb.project_id = cr.project_id
 and jb.cost_code = cr.canonical_cost_code
group by
  cr.project_id,
  cr.project_name,
  cr.project_status,
  cr.raw_cost_code_bucket,
  cr.canonical_cost_code,
  cr.cost_code_status,
  cr.division,
  jb.budget_amount;

comment on view public.v_job_costing_by_project is
  'Per-project cost-code rollup for receipt actuals, taxonomy alignment, and optional manual budgets.';

create or replace view public.v_job_costing_summary as
with matched_receipts as (
  select
    r.id as receipt_id,
    r.job_name,
    r.vendor,
    r.cost_code,
    r.total,
    r.receipt_date,
    rpm.project_id,
    rpm.project_name,
    rpm.project_status
  from public.receipts r
  join public.v_receipt_project_job_match rpm
    on rpm.receipt_id = r.id
  where rpm.project_id is not null
),
receipt_rollup as (
  select
    mr.project_id,
    mr.project_name,
    mr.project_status,
    array_agg(distinct mr.job_name order by mr.job_name) as matched_job_names,
    count(*) as receipt_count,
    count(distinct mr.vendor) as vendor_count,
    sum(mr.total) as actual_total,
    count(*) filter (
      where mr.cost_code is not null
        and exists (
          select 1
          from public.cost_code_taxonomy cct
          where cct.code = mr.cost_code::bpchar
            and cct.is_assignable = true
        )
    ) as coded_receipt_count,
    count(*) filter (where mr.cost_code is null) as uncoded_receipt_count,
    sum(mr.total) filter (where mr.cost_code is null) as uncoded_actual_total,
    count(*) filter (
      where mr.cost_code is not null
        and not exists (
          select 1
          from public.cost_code_taxonomy cct
          where cct.code = mr.cost_code::bpchar
            and cct.is_assignable = true
        )
    ) as noncanonical_receipt_count,
    sum(mr.total) filter (
      where mr.cost_code is not null
        and not exists (
          select 1
          from public.cost_code_taxonomy cct
          where cct.code = mr.cost_code::bpchar
            and cct.is_assignable = true
        )
    ) as noncanonical_actual_total,
    min(mr.receipt_date) as first_receipt_date,
    max(mr.receipt_date) as last_receipt_date
  from matched_receipts mr
  group by
    mr.project_id,
    mr.project_name,
    mr.project_status
),
budget_rollup as (
  select
    jb.project_id,
    count(*) as budget_line_count,
    sum(jb.budget_amount) as budget_total
  from public.job_budgets jb
  group by jb.project_id
),
cost_bucket_rollup as (
  select
    v.project_id,
    count(*) as cost_bucket_count,
    count(*) filter (where v.cost_code_status = 'mapped') as mapped_cost_bucket_count,
    count(*) filter (where v.cost_code_status = 'uncoded') as uncoded_cost_bucket_count,
    count(*) filter (where v.cost_code_status = 'noncanonical') as noncanonical_cost_bucket_count
  from public.v_job_costing_by_project v
  group by v.project_id
)
select
  rr.project_id,
  rr.project_name,
  rr.project_status,
  rr.matched_job_names,
  rr.receipt_count,
  rr.vendor_count,
  rr.actual_total,
  coalesce(br.budget_total, 0) as budget_total,
  rr.actual_total - coalesce(br.budget_total, 0) as budget_variance,
  rr.coded_receipt_count,
  rr.uncoded_receipt_count,
  coalesce(rr.uncoded_actual_total, 0) as uncoded_actual_total,
  rr.noncanonical_receipt_count,
  coalesce(rr.noncanonical_actual_total, 0) as noncanonical_actual_total,
  round((rr.coded_receipt_count::numeric / nullif(rr.receipt_count, 0)) * 100, 1) as code_coverage_pct,
  coalesce(br.budget_line_count, 0) as budget_line_count,
  coalesce(cbr.cost_bucket_count, 0) as cost_bucket_count,
  coalesce(cbr.mapped_cost_bucket_count, 0) as mapped_cost_bucket_count,
  coalesce(cbr.uncoded_cost_bucket_count, 0) as uncoded_cost_bucket_count,
  coalesce(cbr.noncanonical_cost_bucket_count, 0) as noncanonical_cost_bucket_count,
  rr.first_receipt_date,
  rr.last_receipt_date
from receipt_rollup rr
left join budget_rollup br
  on br.project_id = rr.project_id
left join cost_bucket_rollup cbr
  on cbr.project_id = rr.project_id;

comment on view public.v_job_costing_summary is
  'Project-level rollup for actuals, budgets, and cost-code coverage quality.';

create or replace function public.job_costing_report(p_project_name text)
returns jsonb
language sql
stable
set search_path = public
as $$
  with target as (
    select public.normalize_job_costing_key(p_project_name) as project_key
  ),
  alias_pool as (
    select
      p.id as project_id,
      p.name as project_name,
      p.status as project_status,
      'project_name'::text as alias_source,
      null::text as alias_type,
      null::text as alias_origin,
      p.name as alias_text,
      public.normalize_job_costing_key(p.name) as alias_key,
      0 as source_rank
    from public.projects p
    where p.project_kind = 'client'
      and p.status in ('active', 'warranty', 'estimating')

    union all

    select
      p.id as project_id,
      p.name as project_name,
      p.status as project_status,
      case
        when pa.alias_type = 'shorthand' and pa.source = 'manual_review' then 'project_alias_shorthand_manual'
        when pa.alias_type = 'shorthand' then 'project_alias_shorthand'
        when pa.source = 'manual_review' then 'project_alias_manual'
        else 'project_alias'
      end as alias_source,
      pa.alias_type,
      pa.source as alias_origin,
      pa.alias as alias_text,
      public.normalize_job_costing_key(pa.alias) as alias_key,
      case
        when pa.alias_type = 'shorthand' and pa.source = 'manual_review' then 1
        when pa.alias_type = 'shorthand' then 2
        when pa.source = 'manual_review' then 3
        else 4
      end as source_rank
    from public.projects p
    join public.project_aliases pa
      on pa.project_id = p.id
     and pa.active = true
    where p.project_kind = 'client'
      and p.status in ('active', 'warranty', 'estimating')
      and public.normalize_job_costing_key(pa.alias) is not null

    union all

    select
      p.id as project_id,
      p.name as project_name,
      p.status as project_status,
      'project_alias_array'::text as alias_source,
      null::text as alias_type,
      'projects.aliases'::text as alias_origin,
      alias_item.alias_text,
      public.normalize_job_costing_key(alias_item.alias_text) as alias_key,
      5 as source_rank
    from public.projects p
    cross join lateral unnest(coalesce(p.aliases, array[]::text[])) as alias_item(alias_text)
    where p.project_kind = 'client'
      and p.status in ('active', 'warranty', 'estimating')
      and public.normalize_job_costing_key(alias_item.alias_text) is not null
  ),
  project_level_matches as (
    select distinct on (ap.project_id)
      ap.project_id,
      ap.project_name,
      ap.project_status,
      ap.alias_source,
      ap.alias_type,
      ap.alias_origin,
      ap.alias_text as matched_alias,
      case
        when ap.alias_text = p_project_name then 0
        when lower(ap.alias_text) = lower(p_project_name) then 1
        else 2
      end as text_match_rank,
      ap.source_rank,
      case ap.project_status
        when 'active' then 0
        when 'warranty' then 1
        when 'estimating' then 2
        else 9
      end as status_rank
    from alias_pool ap
    join target t
      on ap.alias_key = t.project_key
    order by
      ap.project_id,
      case
        when ap.alias_text = p_project_name then 0
        when lower(ap.alias_text) = lower(p_project_name) then 1
        else 2
      end,
      ap.source_rank,
      length(ap.alias_text),
      ap.alias_text
  ),
  resolved_project as (
    select distinct on (plm.project_name)
      plm.project_id,
      plm.project_name,
      plm.project_status,
      plm.matched_alias,
      plm.alias_source,
      plm.alias_type,
      plm.alias_origin
    from project_level_matches plm
    order by
      plm.project_name,
      plm.text_match_rank,
      plm.source_rank,
      plm.status_rank,
      length(plm.matched_alias),
      plm.project_id
  ),
  chosen_project as (
    select rp.*
    from resolved_project rp
    order by
      case rp.project_status
        when 'active' then 0
        when 'warranty' then 1
        when 'estimating' then 2
        else 9
      end,
      rp.project_name,
      rp.project_id
    limit 1
  ),
  summary_row as (
    select s.*
    from public.v_job_costing_summary s
    join chosen_project cp
      on cp.project_id = s.project_id
  ),
  detail_rows as (
    select v.*
    from public.v_job_costing_by_project v
    join chosen_project cp
      on cp.project_id = v.project_id
  ),
  gap_receipts as (
    select
      r.id,
      r.receipt_date,
      r.vendor,
      r.filename,
      r.invoice_or_transaction,
      r.total,
      r.cost_code,
      r.cost_code_name,
      r.cost_type,
      r.status,
      r.notes
    from public.receipts r
    join public.v_receipt_project_job_match rpm
      on rpm.receipt_id = r.id
    join chosen_project cp
      on cp.project_id = rpm.project_id
    left join public.cost_code_taxonomy cct
      on cct.code = r.cost_code::bpchar
     and cct.is_assignable = true
    where r.cost_code is null
       or cct.code is null
    order by r.receipt_date desc, r.vendor, r.id
  )
  select coalesce(
    (
      select jsonb_build_object(
        'requested_project_name', p_project_name,
        'resolved_project_id', cp.project_id,
        'resolved_project_name', cp.project_name,
        'resolved_project_status', cp.project_status,
        'matched_alias', cp.matched_alias,
        'alias_source', cp.alias_source,
        'summary', to_jsonb(sr),
        'cost_code_lines', coalesce(
          (
            select jsonb_agg(to_jsonb(dr) order by dr.cost_code_status, dr.raw_cost_code_bucket)
            from detail_rows dr
          ),
          '[]'::jsonb
        ),
        'missing_or_noncanonical_receipts', coalesce(
          (
            select jsonb_agg(to_jsonb(gr) order by gr.receipt_date desc, gr.vendor, gr.id)
            from gap_receipts gr
          ),
          '[]'::jsonb
        )
      )
      from chosen_project cp
      join summary_row sr
        on sr.project_id = cp.project_id
    ),
    jsonb_build_object(
      'requested_project_name', p_project_name,
      'error', 'project_not_found'
    )
  );
$$;

comment on function public.job_costing_report(text) is
  'Returns a JSON report with BuilderTrend-style job-costing summary, cost-code lines, and cost-code gaps for a project name or alias.';

commit;
