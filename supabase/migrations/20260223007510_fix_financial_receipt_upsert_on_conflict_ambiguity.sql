-- Hotfix: avoid PL/pgSQL output-variable ambiguity in ON CONFLICT target for financial receipt upsert.
-- Root cause: RETURNS TABLE exposes dedupe_key as variable, causing 'on conflict (dedupe_key)' ambiguity at runtime.

create or replace function public.upsert_financial_claim_receipt_v1(
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
#variable_conflict use_column
declare
  v_dedupe_key text;
  v_candidate_fingerprint text;
  v_evidence_fingerprint text;
  v_payload_hash text;
  v_claim_type text;
  v_acceptance_level text;
  v_reason_codes text[] := '{}'::text[];
  v_claim_id uuid;
  v_project_id uuid;
  v_vendor_id uuid;
  v_receipt_id uuid;
  v_hit_count integer;
  v_first_seen_at timestamptz;
  v_last_seen_at timestamptz;
  v_review_exists boolean := false;
  v_review_created boolean := false;
  v_existing_payload_hash text;
begin
  if p_receipt is null or jsonb_typeof(p_receipt) <> 'object' then
    raise exception 'p_receipt must be a jsonb object';
  end if;

  select d.dedupe_key, d.candidate_fingerprint, d.evidence_fingerprint
  into v_dedupe_key, v_candidate_fingerprint, v_evidence_fingerprint
  from public.financial_claim_receipt_v1_dedupe_key(p_receipt) d;

  v_payload_hash := md5(coalesce(p_receipt::text, '{}'));

  v_claim_type := case
    when lower(trim(coalesce(p_receipt->>'claim_type', ''))) in ('cost_signal', 'scope_signal', 'invoice_link', 'commitment')
      then lower(trim(p_receipt->>'claim_type'))
    else 'cost_signal'
  end;

  v_acceptance_level := case
    when lower(trim(coalesce(p_receipt->>'acceptance_level', ''))) in ('proposed', 'review', 'accepted_planning', 'accepted_execution', 'rejected')
      then lower(trim(p_receipt->>'acceptance_level'))
    else 'proposed'
  end;

  if jsonb_typeof(p_receipt->'reason_codes') = 'array' then
    select coalesce(array_agg(x), '{}'::text[])
    into v_reason_codes
    from (
      select distinct lower(trim(value)) as x
      from jsonb_array_elements_text(p_receipt->'reason_codes')
      where nullif(trim(value), '') is not null
      order by lower(trim(value))
    ) q;
  end if;

  v_claim_id := case
    when coalesce(p_receipt->>'claim_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (p_receipt->>'claim_id')::uuid
    else null
  end;

  v_project_id := case
    when coalesce(p_receipt->>'project_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (p_receipt->>'project_id')::uuid
    else null
  end;

  v_vendor_id := case
    when coalesce(p_receipt->>'vendor_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (p_receipt->>'vendor_id')::uuid
    else null
  end;

  select r.payload_hash
  into v_existing_payload_hash
  from public.financial_claim_receipts_v1 r
  where r.dedupe_key = v_dedupe_key;

  insert into public.financial_claim_receipts_v1 (
    dedupe_key,
    claim_id,
    project_id,
    vendor_id,
    claim_type,
    acceptance_level,
    candidate_fingerprint,
    evidence_fingerprint,
    reason_codes,
    payload_hash,
    receipt_payload,
    last_source_type,
    last_source_id
  ) values (
    v_dedupe_key,
    v_claim_id,
    v_project_id,
    v_vendor_id,
    v_claim_type,
    v_acceptance_level,
    v_candidate_fingerprint,
    v_evidence_fingerprint,
    v_reason_codes,
    v_payload_hash,
    p_receipt,
    p_last_source_type,
    p_last_source_id
  )
  on conflict (dedupe_key) do update
    set hit_count = public.financial_claim_receipts_v1.hit_count + 1,
        last_seen_at_utc = now(),
        claim_id = coalesce(excluded.claim_id, public.financial_claim_receipts_v1.claim_id),
        project_id = coalesce(excluded.project_id, public.financial_claim_receipts_v1.project_id),
        vendor_id = coalesce(excluded.vendor_id, public.financial_claim_receipts_v1.vendor_id),
        claim_type = excluded.claim_type,
        acceptance_level = excluded.acceptance_level,
        candidate_fingerprint = excluded.candidate_fingerprint,
        evidence_fingerprint = excluded.evidence_fingerprint,
        reason_codes = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.financial_claim_receipts_v1.reason_codes, '{}'::text[])
            || coalesce(excluded.reason_codes, '{}'::text[])
            || case
                 when public.financial_claim_receipts_v1.payload_hash <> excluded.payload_hash
                   then array['replayed_payload_delta']::text[]
                 else '{}'::text[]
               end
          ) as u(x)
          where nullif(trim(u.x), '') is not null
        ),
        payload_hash = excluded.payload_hash,
        receipt_payload = case
          when public.financial_claim_receipts_v1.payload_hash <> excluded.payload_hash
            then excluded.receipt_payload
          else public.financial_claim_receipts_v1.receipt_payload
        end,
        last_source_type = coalesce(excluded.last_source_type, public.financial_claim_receipts_v1.last_source_type),
        last_source_id = coalesce(excluded.last_source_id, public.financial_claim_receipts_v1.last_source_id)
  returning
    public.financial_claim_receipts_v1.id,
    public.financial_claim_receipts_v1.hit_count,
    public.financial_claim_receipts_v1.first_seen_at_utc,
    public.financial_claim_receipts_v1.last_seen_at_utc
  into v_receipt_id, v_hit_count, v_first_seen_at, v_last_seen_at;

  if v_acceptance_level in ('proposed', 'review') then
    select exists(
      select 1
      from public.financial_claim_review_queue_v1 q
      where q.dedupe_key = v_dedupe_key
    ) into v_review_exists;

    insert into public.financial_claim_review_queue_v1 (
      dedupe_key,
      claim_receipt_id,
      review_state,
      reason_codes,
      routed_at_utc,
      updated_at_utc
    ) values (
      v_dedupe_key,
      v_receipt_id,
      'open',
      coalesce(v_reason_codes, '{}'::text[]),
      now(),
      now()
    )
    on conflict (dedupe_key) do update
      set claim_receipt_id = excluded.claim_receipt_id,
          reason_codes = (
            select coalesce(array_agg(distinct x order by x), '{}'::text[])
            from unnest(
              coalesce(public.financial_claim_review_queue_v1.reason_codes, '{}'::text[])
              || coalesce(excluded.reason_codes, '{}'::text[])
            ) as u(x)
            where nullif(trim(u.x), '') is not null
          ),
          updated_at_utc = now();

    v_review_created := not v_review_exists;
  end if;

  return query
  select
    v_receipt_id,
    v_dedupe_key,
    (v_hit_count > 1) as is_duplicate,
    v_hit_count,
    v_first_seen_at,
    v_last_seen_at,
    v_review_created;
end;
$$;
comment on function public.upsert_financial_claim_receipt_v1 is
  'Atomic insert/replay upsert for financial receipts v1: deterministic dedupe_key, hit_count increment, last_seen update, optional review queue row. Hotfix: ON CONFLICT references unique constraint to avoid variable ambiguity.';
