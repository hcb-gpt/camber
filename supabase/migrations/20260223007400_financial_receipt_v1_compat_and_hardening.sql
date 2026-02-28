-- Financial receipts v1 compatibility + hardening layer.
-- Goals:
-- 1) Keep queue timestamps monotonic with an update trigger.
-- 2) Provide assertion-compatible read surfaces without mutating base tables.
-- 3) Restrict finance receipt RPC execution to service_role.

begin;
create or replace function public.tg_set_updated_at_utc()
returns trigger
language plpgsql
as $$
begin
  new.updated_at_utc = now();
  return new;
end;
$$;
drop trigger if exists trg_financial_claim_review_queue_v1_updated_at_utc
  on public.financial_claim_review_queue_v1;
create trigger trg_financial_claim_review_queue_v1_updated_at_utc
before update on public.financial_claim_review_queue_v1
for each row execute function public.tg_set_updated_at_utc();
create or replace view public.financial_claim_receipts_v1_assertions as
select
  r.id,
  r.dedupe_key,
  r.hit_count,
  r.payload_hash as last_payload_hash,
  coalesce(lower(nullif(r.receipt_payload->>'risk_level', '')), 'normal') as risk_level,
  case
    when jsonb_typeof(r.receipt_payload->'world_contact_evidence') = 'boolean'
      then (r.receipt_payload->>'world_contact_evidence')::boolean
    else false
  end as world_contact_evidence,
  r.acceptance_level as disposition,
  r.claim_type,
  r.first_seen_at_utc,
  r.last_seen_at_utc
from public.financial_claim_receipts_v1 r;
comment on view public.financial_claim_receipts_v1_assertions is
  'Assertion-friendly projection of financial_claim_receipts_v1 for canary checks (maps payload_hash/risk/world-contact/disposition fields).';
create or replace view public.review_queue_v1 as
select
  q.dedupe_key as receipt_dedupe_key,
  rc.reason,
  q.review_state as status,
  q.claim_receipt_id,
  q.routed_at_utc,
  q.updated_at_utc,
  q.resolved_at_utc
from public.financial_claim_review_queue_v1 q
left join lateral (
  select unnest(
    case
      when coalesce(array_length(q.reason_codes, 1), 0) = 0
        then array[null::text]
      else q.reason_codes
    end
  ) as reason
) rc on true;
comment on view public.review_queue_v1 is
  'Compatibility projection for canary assertions over financial_claim_review_queue_v1 (receipt_dedupe_key + reason rows).';
revoke execute on function public.upsert_financial_claim_receipt_v1(jsonb, text, text)
  from public, anon, authenticated;
grant execute on function public.upsert_financial_claim_receipt_v1(jsonb, text, text)
  to service_role;
revoke execute on function public.upsert_financial_claim_receipt_v1_strict(jsonb, text, text)
  from public, anon, authenticated;
grant execute on function public.upsert_financial_claim_receipt_v1_strict(jsonb, text, text)
  to service_role;
revoke execute on function public.financial_claim_receipt_v1_dedupe_key(jsonb)
  from public, anon, authenticated;
grant execute on function public.financial_claim_receipt_v1_dedupe_key(jsonb)
  to service_role;
revoke execute on function public.financial_claim_receipt_v1_apply_policy(jsonb)
  from public, anon, authenticated;
grant execute on function public.financial_claim_receipt_v1_apply_policy(jsonb)
  to service_role;
commit;
