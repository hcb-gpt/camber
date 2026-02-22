-- Post-apply proof checks for:
-- 20260222064600_patch_scheduler_financial_writer.sql
--
-- Usage:
--   scripts/query.sh --file scripts/proof_financial_writer_apply.sql

\pset pager off

-- 1) Main verification counts (must show rows_with_any_amount > 0 after apply/backfill)
with parsed as (
  select
    id,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_committed}',''),'[^0-9.-]','','g'),'')::numeric
    ) as committed,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_invoiced}',''),'[^0-9.-]','','g'),'')::numeric
    ) as invoiced,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_pending}',''),'[^0-9.-]','','g'),'')::numeric
    ) as pending
  from scheduler_items
  where financial_json is not null
)
select
  count(*) as rows_financial_json,
  count(*) filter (where committed is not null) as rows_with_committed,
  count(*) filter (where invoiced is not null) as rows_with_invoiced,
  count(*) filter (where pending is not null) as rows_with_pending,
  count(*) filter (where committed is not null or invoiced is not null or pending is not null) as rows_with_any_amount
from parsed;

-- 2) Real data pointers (sample scheduler_items rows with canonical keys)
select
  id,
  interaction_id,
  project_id,
  financial_json->>'total_committed' as total_committed,
  financial_json->>'total_invoiced' as total_invoiced,
  financial_json->>'total_pending' as total_pending,
  financial_json->>'largest_single_item' as largest_single_item,
  financial_json->>'normalized_by' as normalized_by
from scheduler_items
where financial_json is not null
  and (
    financial_json->>'total_committed' is not null
    or financial_json->>'total_invoiced' is not null
    or financial_json->>'total_pending' is not null
  )
order by updated_at desc nulls last, created_at desc
limit 10;

-- 3) Downstream smoke: v_financial_exposure
select
  project_id,
  project_name,
  total_committed,
  total_invoiced,
  total_pending,
  item_count,
  largest_single_item
from public.v_financial_exposure
order by total_pending desc nulls last
limit 10;
