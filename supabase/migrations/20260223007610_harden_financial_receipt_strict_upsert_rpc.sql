-- Harden strict wrapper for financial receipt v1 ingest.
-- Additive update: replaces strict wrapper with deeper contract checks.

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
  v_vendor_id text;
  v_risk_level text := 'normal';
  v_world_contact_evidence boolean := false;
  v_row jsonb;
  v_score_text text;
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

  v_vendor_id := trim(coalesce(p_receipt->>'vendor_id', ''));
  if v_vendor_id <> '' and v_vendor_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'invalid_receipt: vendor_id must be uuid when provided';
  end if;

  if p_receipt ? 'risk_level' then
    v_risk_level := lower(trim(coalesce(p_receipt->>'risk_level', '')));
    if v_risk_level not in ('normal', 'high') then
      raise exception 'invalid_receipt: risk_level must be one of normal|high';
    end if;
  end if;

  if p_receipt ? 'world_contact_evidence' then
    if jsonb_typeof(p_receipt->'world_contact_evidence') <> 'boolean' then
      raise exception 'invalid_receipt: world_contact_evidence must be boolean when provided';
    end if;
    v_world_contact_evidence := (p_receipt->>'world_contact_evidence')::boolean;
  end if;

  if v_risk_level = 'high'
     and not v_world_contact_evidence
     and v_acceptance_level in ('accepted_planning', 'accepted_execution') then
    raise exception 'invalid_receipt: high-risk receipts require world_contact_evidence=true before accepted_* levels';
  end if;

  if p_receipt ? 'reason_codes' and jsonb_typeof(p_receipt->'reason_codes') <> 'array' then
    raise exception 'invalid_receipt: reason_codes must be array when provided';
  end if;

  if p_receipt ? 'candidate_cost_codes' then
    if jsonb_typeof(p_receipt->'candidate_cost_codes') <> 'array' then
      raise exception 'invalid_receipt: candidate_cost_codes must be array when provided';
    end if;
    for v_row in
      select value from jsonb_array_elements(p_receipt->'candidate_cost_codes')
    loop
      if jsonb_typeof(v_row) <> 'object' then
        raise exception 'invalid_receipt: candidate_cost_codes entries must be objects';
      end if;
      if trim(coalesce(v_row->>'code', '')) = '' then
        raise exception 'invalid_receipt: candidate_cost_codes.code is required';
      end if;
      if v_row ? 'score' then
        v_score_text := trim(coalesce(v_row->>'score', ''));
        if v_score_text = '' or v_score_text !~ '^-?[0-9]+(\.[0-9]+)?$' then
          raise exception 'invalid_receipt: candidate_cost_codes.score must be numeric when provided';
        end if;
        if (v_score_text::numeric < 0) or (v_score_text::numeric > 1) then
          raise exception 'invalid_receipt: candidate_cost_codes.score must be in [0,1]';
        end if;
      end if;
    end loop;
  end if;

  if jsonb_typeof(p_receipt->'evidence') <> 'array' or jsonb_array_length(p_receipt->'evidence') = 0 then
    raise exception 'invalid_receipt: evidence must be a non-empty array';
  end if;

  for v_row in
    select value from jsonb_array_elements(p_receipt->'evidence')
  loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'invalid_receipt: evidence entries must be objects';
    end if;
    if trim(coalesce(v_row->>'source_type', '')) = '' then
      raise exception 'invalid_receipt: evidence.source_type is required';
    end if;
    if trim(coalesce(v_row->>'source_id', '')) = '' then
      raise exception 'invalid_receipt: evidence.source_id is required';
    end if;
    if jsonb_typeof(v_row->'pointer') <> 'object' then
      raise exception 'invalid_receipt: evidence.pointer is required';
    end if;
    if trim(coalesce(v_row->'pointer'->>'kind', '')) = '' then
      raise exception 'invalid_receipt: evidence.pointer.kind is required';
    end if;
  end loop;

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
  'Strict wrapper v2 for financial receipt v1 upsert. Enforces required fields, evidence structure, optional candidate score bounds, and high-risk world-contact gate before delegating to upsert_financial_claim_receipt_v1.';
grant execute on function public.upsert_financial_claim_receipt_v1_strict(
  jsonb, text, text
) to service_role;
