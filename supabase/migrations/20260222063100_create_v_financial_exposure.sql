-- Create v_financial_exposure from scheduler_items.financial_json
-- Purpose: project-level rollup of committed/invoiced/pending exposure.

create or replace view public.v_financial_exposure as
with item_financials as (
  select
    si.id as scheduler_item_id,
    si.created_at,
    coalesce(
      si.project_id,
      case
        when coalesce(si.financial_json->>'project_id', '') ~* '^[0-9a-f-]{36}$'
          then (si.financial_json->>'project_id')::uuid
        else null
      end
    ) as resolved_project_id,
    nullif(coalesce(si.financial_json->>'project_name', ''), '') as project_name_from_json,
    coalesce(
      nullif(regexp_replace(coalesce(si.financial_json->>'total_committed', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'committed', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'amount_committed', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json #>> '{financial,total_committed}', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      0::numeric
    ) as committed_amount,
    coalesce(
      nullif(regexp_replace(coalesce(si.financial_json->>'total_invoiced', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'invoiced', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'amount_invoiced', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json #>> '{financial,total_invoiced}', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      0::numeric
    ) as invoiced_amount,
    coalesce(
      nullif(regexp_replace(coalesce(si.financial_json->>'total_pending', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'pending', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'amount_pending', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json #>> '{financial,total_pending}', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      0::numeric
    ) as pending_amount,
    coalesce(
      nullif(regexp_replace(coalesce(si.financial_json->>'largest_single_item', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'single_item_amount', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'amount', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(si.financial_json->>'value', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      0::numeric
    ) as largest_single_item_candidate
  from public.scheduler_items si
  where si.financial_json is not null
)
select
  f.resolved_project_id as project_id,
  coalesce(p.name, f.project_name_from_json, 'UNMAPPED') as project_name,
  sum(f.committed_amount) as total_committed,
  sum(f.invoiced_amount) as total_invoiced,
  sum(f.pending_amount) as total_pending,
  count(*)::bigint as item_count,
  max(greatest(
    f.largest_single_item_candidate,
    f.committed_amount,
    f.invoiced_amount,
    f.pending_amount
  )) as largest_single_item,
  case
    when count(*) filter (where f.pending_amount > 0) = 0 then null
    else floor(extract(epoch from (now() - min(f.created_at) filter (where f.pending_amount > 0))) / 86400)::int
  end as oldest_unpaid_days
from item_financials f
left join public.projects p
  on p.id = f.resolved_project_id
group by f.resolved_project_id, coalesce(p.name, f.project_name_from_json, 'UNMAPPED');
comment on view public.v_financial_exposure is
  'Project-level financial exposure rollup from scheduler_items.financial_json.';
