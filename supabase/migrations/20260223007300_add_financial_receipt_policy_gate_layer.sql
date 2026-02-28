-- Financial receipts v1 policy-gate layer (additive)
-- Goals:
-- 1) Normalize policy fields in receipt payload
-- 2) Enforce high-risk world-contact gate before strict upsert
-- 3) Preserve existing return contract from upsert_financial_claim_receipt_v1_strict
-- 4) Expose policy audit view for operators

create or replace function public.financial_claim_receipt_v1_apply_policy(
  p_receipt jsonb
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_receipt jsonb := coalesce(p_receipt, '{}'::jsonb);
  v_reason_codes text[] := '{}'::text[];
  v_acceptance_level text;
  v_risk_level text := 'normal';
  v_world_contact_evidence boolean := false;
  v_has_ambiguous boolean := false;
  v_gate_triggered boolean := false;
begin
  if jsonb_typeof(v_receipt) <> 'object' then
    raise exception 'invalid_receipt: p_receipt must be a json object';
  end if;

  if jsonb_typeof(v_receipt->'reason_codes') = 'array' then
    select coalesce(array_agg(x), '{}'::text[])
    into v_reason_codes
    from (
      select distinct lower(trim(value)) as x
      from jsonb_array_elements_text(v_receipt->'reason_codes')
      where nullif(trim(value), '') is not null
      order by lower(trim(value))
    ) q;
  end if;

  v_acceptance_level := lower(trim(coalesce(v_receipt->>'acceptance_level', 'proposed')));
  if v_acceptance_level not in ('proposed', 'review', 'accepted_planning', 'accepted_execution', 'rejected') then
    v_acceptance_level := 'proposed';
  end if;

  v_risk_level := lower(trim(coalesce(v_receipt->>'risk_level', 'normal')));
  if v_risk_level not in ('normal', 'high') then
    v_risk_level := 'normal';
  end if;

  if jsonb_typeof(v_receipt->'world_contact_evidence') = 'boolean' then
    v_world_contact_evidence := (v_receipt->>'world_contact_evidence')::boolean;
  end if;

  v_has_ambiguous := array_position(v_reason_codes, 'candidate_ambiguous') is not null;

  if v_risk_level = 'high' and not v_world_contact_evidence then
    v_gate_triggered := true;
    v_reason_codes := array_remove(v_reason_codes || array['high_risk_world_contact_missing']::text[], null);
  end if;

  if v_gate_triggered or v_has_ambiguous then
    if v_acceptance_level not in ('proposed', 'review') then
      v_reason_codes := array_remove(v_reason_codes || array['policy_demoted_to_review']::text[], null);
    end if;
    v_acceptance_level := 'review';
  end if;

  select coalesce(array_agg(distinct x order by x), '{}'::text[])
  into v_reason_codes
  from unnest(coalesce(v_reason_codes, '{}'::text[])) u(x)
  where nullif(trim(u.x), '') is not null;

  v_receipt := jsonb_set(v_receipt, '{acceptance_level}', to_jsonb(v_acceptance_level), true);
  v_receipt := jsonb_set(v_receipt, '{risk_level}', to_jsonb(v_risk_level), true);
  v_receipt := jsonb_set(v_receipt, '{world_contact_evidence}', to_jsonb(v_world_contact_evidence), true);
  v_receipt := jsonb_set(v_receipt, '{reason_codes}', to_jsonb(v_reason_codes), true);

  return v_receipt;
end;
$$;
comment on function public.financial_claim_receipt_v1_apply_policy(jsonb) is
  'Normalizes policy fields for financial receipt v1 and enforces high-risk world-contact gate by demoting to review with reason codes.';
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
  v_risk_level text;
  v_policy_receipt jsonb;
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

  v_risk_level := lower(trim(coalesce(p_receipt->>'risk_level', 'normal')));
  if v_risk_level not in ('normal', 'high') then
    raise exception 'invalid_receipt: risk_level must be normal|high when provided';
  end if;

  if p_receipt ? 'world_contact_evidence'
    and jsonb_typeof(p_receipt->'world_contact_evidence') <> 'boolean' then
    raise exception 'invalid_receipt: world_contact_evidence must be boolean when provided';
  end if;

  v_policy_receipt := public.financial_claim_receipt_v1_apply_policy(p_receipt);

  return query
  select *
  from public.upsert_financial_claim_receipt_v1(
    v_policy_receipt,
    p_last_source_type,
    p_last_source_id
  );
end;
$$;
comment on function public.upsert_financial_claim_receipt_v1_strict(jsonb, text, text) is
  'Strict + policy-gated wrapper for financial receipt v1 upsert. Validates required fields, applies high-risk world-contact policy, then delegates to base upsert.';
grant execute on function public.upsert_financial_claim_receipt_v1_strict(
  jsonb, text, text
) to service_role;
create or replace view public.v_financial_claim_receipts_v1_policy_audit as
select
  r.id,
  r.dedupe_key,
  r.claim_type,
  r.acceptance_level,
  r.reason_codes,
  coalesce(lower(nullif(r.receipt_payload->>'risk_level', '')), 'normal') as risk_level,
  case
    when jsonb_typeof(r.receipt_payload->'world_contact_evidence') = 'boolean'
      then (r.receipt_payload->>'world_contact_evidence')::boolean
    else false
  end as world_contact_evidence,
  array_position(r.reason_codes, 'high_risk_world_contact_missing') is not null as high_risk_gate_triggered,
  array_position(r.reason_codes, 'candidate_ambiguous') is not null as ambiguous_candidate_flag,
  r.hit_count,
  r.first_seen_at_utc,
  r.last_seen_at_utc
from public.financial_claim_receipts_v1 r;
comment on view public.v_financial_claim_receipts_v1_policy_audit is
  'Policy audit view for financial receipt v1 showing risk/world-contact flags, gate triggers, and replay counters.';
