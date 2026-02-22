-- Patch writer path for scheduler financial amounts.
-- Goal: ensure scheduler_items.financial_json contains standardized numeric keys:
-- total_committed, total_invoiced, total_pending, largest_single_item.

create or replace function public._safe_amount(p_text text)
returns numeric
language plpgsql
immutable
as $$
declare
  v_clean text;
begin
  if p_text is null then
    return null;
  end if;

  v_clean := nullif(regexp_replace(p_text, '[^0-9.\-]', '', 'g'), '');
  if v_clean is null or v_clean !~ '^-?[0-9]+(\.[0-9]+)?$' then
    return null;
  end if;

  return v_clean::numeric;
end;
$$;

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
    'normalized_by', 'materialize_scheduler_items_v2'
  );
end;
$$;

create or replace function public.materialize_scheduler_items()
returns trigger
language plpgsql
as $$
declare
  item jsonb;
  item_hash_val text;
begin
  -- Only proceed if ai_scheduler_json is a non-empty array
  if new.ai_scheduler_json is null
     or jsonb_typeof(new.ai_scheduler_json) != 'array'
     or jsonb_array_length(new.ai_scheduler_json) = 0 then
    return new;
  end if;

  for item in select jsonb_array_elements(new.ai_scheduler_json)
  loop
    -- Compute deterministic hash for idempotency (matches old pipeline pattern)
    item_hash_val := left(md5(
      coalesce(item->>'title', '') || '|' || coalesce(item->>'action', '')
    ), 8);

    insert into public.scheduler_items (
      interaction_id,
      item_type,
      title,
      description,
      time_hint,
      assignee,
      status,
      source,
      item_hash,
      project_id,
      attribution_status,
      attribution_confidence,
      needs_review,
      evidence_quote,
      evidence_locator,
      scheduler_schema_version,
      financial_json,
      payload,
      meta
    ) values (
      new.id,  -- FK to interactions.id (UUID)
      coalesce(item->>'item_type', 'task'),
      coalesce(item->>'title', 'Untitled'),
      coalesce(item->>'action', item->>'description', ''),
      item->>'due_hint',
      item->>'owner',
      'pending',
      coalesce(item->>'source', 'generate-summary'),
      item_hash_val,
      new.project_id,  -- inherit from interaction if available
      case
        when new.project_id is not null then 'resolved'
        else 'unknown'
      end,
      case
        when new.project_id is not null then 0.80
        else null
      end,
      new.project_id is null,  -- needs_review if no project
      item->>'evidence_quote',
      item->>'evidence_locator',
      4,  -- schema version 4 for generate-summary source
      public.normalize_scheduler_item_financial(item, new.financial_json, null),
      item,  -- store full original JSON in payload
      jsonb_build_object(
        'prompt_version', item->>'prompt_version',
        'priority', item->>'priority',
        'span_index_hint', item->>'span_index_hint',
        'generated_at_utc', item->>'generated_at_utc',
        'materialized_by', 'trg_materialize_scheduler_items'
      )
    )
    on conflict (interaction_id, item_hash) do update
      set financial_json = coalesce(
        excluded.financial_json,
        public.scheduler_items.financial_json
      );
  end loop;

  return new;
end;
$$;

comment on function public.materialize_scheduler_items() is
  'Materializes scheduler items from interactions.ai_scheduler_json into scheduler_items and normalizes financial_json keys: '
  'total_committed,total_invoiced,total_pending,largest_single_item.';

-- Backfill existing rows where normalized keys are missing or financial_json is null.
update public.scheduler_items si
set financial_json = public.normalize_scheduler_item_financial(
  si.payload,
  i.financial_json,
  si.financial_json
)
from public.interactions i
where i.id = si.interaction_id
  and (
    si.financial_json is null
    or si.financial_json->>'total_committed' is null
    or si.financial_json->>'total_invoiced' is null
    or si.financial_json->>'total_pending' is null
    or si.financial_json->>'largest_single_item' is null
  );
