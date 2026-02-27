-- Guard financial normalization so non-financial scheduler items do not emit synthetic zero totals.
-- Root cause: materialize_scheduler_items_v2 normalization coalesced missing totals to 0 whenever
-- generic context existed, causing non-financial rows to appear in v_financial_exposure.

create or replace function public.normalize_scheduler_item_financial(
  p_item jsonb,
  p_interaction_financial jsonb,
  p_existing_financial jsonb default null
)
returns jsonb
language plpgsql
as $$
declare
  v_item jsonb := coalesce(p_item, '{}'::jsonb);
  v_interaction jsonb := coalesce(p_interaction_financial, '{}'::jsonb);
  v_existing jsonb := coalesce(p_existing_financial, '{}'::jsonb);
  v_base jsonb := '{}'::jsonb;
  v_total_committed numeric;
  v_total_invoiced numeric;
  v_total_pending numeric;
  v_largest_single_item numeric;
  v_has_financial_context boolean := false;
  v_has_amount_signal boolean := false;
begin
  if jsonb_typeof(v_existing) = 'object' and v_existing <> '{}'::jsonb then
    v_base := v_existing;
  elsif jsonb_typeof(v_item->'financial_json') = 'object' then
    v_base := v_item->'financial_json';
  elsif jsonb_typeof(v_item->'financial') = 'object' then
    v_base := v_item->'financial';
  elsif jsonb_typeof(v_interaction) = 'object' then
    v_base := v_interaction;
  end if;

  v_total_committed := coalesce(
    public._safe_amount(v_item->>'total_committed'),
    public._safe_amount(v_item->>'committed'),
    public._safe_amount(v_item->>'amount_committed'),
    public._safe_amount(v_item #>> '{financial,total_committed}'),
    public._safe_amount(v_item #>> '{financial,committed}'),
    public._safe_amount(v_item #>> '{financial,amount_committed}'),
    public._safe_amount(v_existing->>'total_committed'),
    public._safe_amount(v_existing->>'committed'),
    public._safe_amount(v_existing->>'amount_committed'),
    public._safe_amount(v_existing #>> '{financial,total_committed}'),
    public._safe_amount(v_interaction->>'total_committed'),
    public._safe_amount(v_interaction->>'committed'),
    public._safe_amount(v_interaction->>'amount_committed'),
    public._safe_amount(v_interaction #>> '{financial,total_committed}')
  );

  v_total_invoiced := coalesce(
    public._safe_amount(v_item->>'total_invoiced'),
    public._safe_amount(v_item->>'invoiced'),
    public._safe_amount(v_item->>'amount_invoiced'),
    public._safe_amount(v_item #>> '{financial,total_invoiced}'),
    public._safe_amount(v_item #>> '{financial,invoiced}'),
    public._safe_amount(v_item #>> '{financial,amount_invoiced}'),
    public._safe_amount(v_existing->>'total_invoiced'),
    public._safe_amount(v_existing->>'invoiced'),
    public._safe_amount(v_existing->>'amount_invoiced'),
    public._safe_amount(v_existing #>> '{financial,total_invoiced}'),
    public._safe_amount(v_interaction->>'total_invoiced'),
    public._safe_amount(v_interaction->>'invoiced'),
    public._safe_amount(v_interaction->>'amount_invoiced'),
    public._safe_amount(v_interaction #>> '{financial,total_invoiced}')
  );

  v_total_pending := coalesce(
    public._safe_amount(v_item->>'total_pending'),
    public._safe_amount(v_item->>'pending'),
    public._safe_amount(v_item->>'amount_pending'),
    public._safe_amount(v_item #>> '{financial,total_pending}'),
    public._safe_amount(v_item #>> '{financial,pending}'),
    public._safe_amount(v_item #>> '{financial,amount_pending}'),
    public._safe_amount(v_existing->>'total_pending'),
    public._safe_amount(v_existing->>'pending'),
    public._safe_amount(v_existing->>'amount_pending'),
    public._safe_amount(v_existing #>> '{financial,total_pending}'),
    public._safe_amount(v_interaction->>'total_pending'),
    public._safe_amount(v_interaction->>'pending'),
    public._safe_amount(v_interaction->>'amount_pending'),
    public._safe_amount(v_interaction #>> '{financial,total_pending}')
  );

  v_largest_single_item := coalesce(
    public._safe_amount(v_item->>'largest_single_item'),
    public._safe_amount(v_item->>'single_item_amount'),
    public._safe_amount(v_item->>'amount'),
    public._safe_amount(v_item #>> '{financial,largest_single_item}'),
    public._safe_amount(v_existing->>'largest_single_item'),
    public._safe_amount(v_existing->>'single_item_amount'),
    public._safe_amount(v_existing #>> '{financial,largest_single_item}'),
    public._safe_amount(v_interaction->>'largest_single_item'),
    public._safe_amount(v_interaction->>'single_item_amount'),
    public._safe_amount(v_interaction #>> '{financial,largest_single_item}'),
    (
      select max(public._safe_amount(elem->>'amount'))
      from jsonb_array_elements(
        case
          when jsonb_typeof(v_item->'line_items') = 'array' then v_item->'line_items'
          when jsonb_typeof(v_item #> '{financial,line_items}') = 'array' then v_item #> '{financial,line_items}'
          else '[]'::jsonb
        end
      ) elem
    ),
    (
      select max(public._safe_amount(elem->>'amount'))
      from jsonb_array_elements(
        case
          when jsonb_typeof(v_existing->'line_items') = 'array' then v_existing->'line_items'
          when jsonb_typeof(v_existing #> '{financial,line_items}') = 'array' then v_existing #> '{financial,line_items}'
          else '[]'::jsonb
        end
      ) elem
    )
  );

  v_has_financial_context := (
    (jsonb_typeof(v_base) = 'object' and v_base <> '{}'::jsonb)
    or (v_item ? 'financial')
    or (v_item ? 'financial_json')
    or (v_item ? 'total_committed')
    or (v_item ? 'total_invoiced')
    or (v_item ? 'total_pending')
    or (jsonb_typeof(v_interaction) = 'object' and v_interaction <> '{}'::jsonb)
  );

  v_has_amount_signal := (
    v_total_committed is not null
    or v_total_invoiced is not null
    or v_total_pending is not null
    or v_largest_single_item is not null
    or (v_item ? 'amount')
    or (v_item ? 'value')
    or (v_item ? 'line_items')
    or (v_existing ? 'amount')
    or (v_existing ? 'value')
    or (v_existing ? 'line_items')
    or (v_interaction ? 'amount')
    or (v_interaction ? 'value')
    or (v_interaction ? 'line_items')
  );

  -- If there is no parseable amount signal, do not emit a financial blob.
  if not v_has_amount_signal
     and v_total_committed is null
     and v_total_invoiced is null
     and v_total_pending is null
     and v_largest_single_item is null then
    return null;
  end if;

  if not v_has_financial_context
     and v_total_committed is null
     and v_total_invoiced is null
     and v_total_pending is null
     and v_largest_single_item is null then
    return null;
  end if;

  return coalesce(v_base, '{}'::jsonb) || jsonb_build_object(
    'total_committed', coalesce(v_total_committed, 0),
    'total_invoiced', coalesce(v_total_invoiced, 0),
    'total_pending', coalesce(v_total_pending, 0),
    'largest_single_item', coalesce(
      v_largest_single_item,
      greatest(
        coalesce(v_total_committed, 0),
        coalesce(v_total_invoiced, 0),
        coalesce(v_total_pending, 0)
      )
    ),
    'normalized_by', 'materialize_scheduler_items_v3'
  );
end;
$$;
comment on function public.normalize_scheduler_item_financial(jsonb, jsonb, jsonb) is
  'Normalizes scheduler financial payloads to canonical amount keys; suppresses synthetic zero-only blobs when no amount signal exists (v3).';
-- Bounded cleanup of prior synthetic zero-only rows from v2 normalizer.
update public.scheduler_items si
set financial_json = public.normalize_scheduler_item_financial(
  si.payload,
  i.financial_json,
  si.financial_json
)
from public.interactions i
where i.id = si.interaction_id
  and si.financial_json is not null
  and coalesce(si.financial_json->>'normalized_by', '') = 'materialize_scheduler_items_v2'
  and coalesce(public._safe_amount(si.financial_json->>'total_committed'), 0) = 0
  and coalesce(public._safe_amount(si.financial_json->>'total_invoiced'), 0) = 0
  and coalesce(public._safe_amount(si.financial_json->>'total_pending'), 0) = 0
  and coalesce(public._safe_amount(si.financial_json->>'largest_single_item'), 0) = 0;
