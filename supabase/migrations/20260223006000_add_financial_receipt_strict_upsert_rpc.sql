-- Add strict contract wrapper for financial receipt v1 ingest.
-- This is additive: legacy upsert_financial_claim_receipt_v1 remains unchanged.

create or replace function public.upsert_financial_claim_receipt_v1_strict(
  p_receipt jsonb,
  p_last_source_type text default null,
  p_last_source_id text default null
)
returns table (
  receipt_id uuid,
  dedupe_key text,
  is_duplicate boolean,
  hit_count integer,
  first_seen_at_utc timestamptz,
  last_seen_at_utc timestamptz,
  review_row_created boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claim_type text;
  v_acceptance_level text;
  v_project_id text;
begin
  if p_receipt is null or jsonb_typeof(p_receipt) <> 'object' then
    raise exception 'invalid_receipt: p_receipt must be a json object';
  end if;

  v_claim_type := lower(trim(coalesce(p_receipt->>'claim_type', '')));
  if v_claim_type = '' then
    raise exception 'invalid_receipt: claim_type is required';
  end if;
  if v_claim_type not in ('cost_signal', 'scope_signal', 'invoice_link', 'commitment') then
    raise exception 'invalid_receipt: claim_type must be one of cost_signal|scope_signal|invoice_link|commitment';
  end if;

  v_acceptance_level := lower(trim(coalesce(p_receipt->>'acceptance_level', '')));
  if v_acceptance_level = '' then
    raise exception 'invalid_receipt: acceptance_level is required';
  end if;
  if v_acceptance_level not in ('proposed', 'review', 'accepted_planning', 'accepted_execution', 'rejected') then
    raise exception 'invalid_receipt: acceptance_level must be one of proposed|review|accepted_planning|accepted_execution|rejected';
  end if;

  v_project_id := trim(coalesce(p_receipt->>'project_id', ''));
  if v_project_id = '' then
    raise exception 'invalid_receipt: project_id is required';
  end if;
  if v_project_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'invalid_receipt: project_id must be uuid';
  end if;

  if jsonb_typeof(p_receipt->'evidence') <> 'array' or jsonb_array_length(p_receipt->'evidence') = 0 then
    raise exception 'invalid_receipt: evidence must be a non-empty array';
  end if;

  return query
  select *
  from public.upsert_financial_claim_receipt_v1(
    p_receipt,
    p_last_source_type,
    p_last_source_id
  );
end;
$$;
comment on function public.upsert_financial_claim_receipt_v1_strict is
  'Strict wrapper for financial receipt v1 upsert. Enforces required fields and allowed enums before delegating to upsert_financial_claim_receipt_v1.';
grant execute on function public.upsert_financial_claim_receipt_v1_strict(
  jsonb, text, text
) to service_role;
