-- Proof pack: redline_latest_thread_event_by_phone_v1
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/redline_latest_thread_event_by_phone_v1_proof_20260228.sql

\echo 'Q1) Function exists'
select
  n.nspname as schema,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'redline_latest_thread_event_by_phone_v1';

\echo 'Q2) Sample phones (latest two with redline_thread activity)'
with phones as (
  select contact_phone
  from public.redline_thread
  where coalesce(contact_phone, '') <> ''
  group by contact_phone
  order by max(event_at_utc) desc nulls last
  limit 2
)
select array_agg(contact_phone)::text[] as sample_phones from phones;

\echo 'Q3) RPC output row count for sample phones'
with phones as (
  select contact_phone
  from public.redline_thread
  where coalesce(contact_phone, '') <> ''
  group by contact_phone
  order by max(event_at_utc) desc nulls last
  limit 2
),
out as (
  select *
  from public.redline_latest_thread_event_by_phone_v1((select array_agg(contact_phone)::text[] from phones))
)
select count(*)::int as output_rows from out;

\echo 'Q4) RPC output rows'
with phones as (
  select contact_phone
  from public.redline_thread
  where coalesce(contact_phone, '') <> ''
  group by contact_phone
  order by max(event_at_utc) desc nulls last
  limit 2
)
select *
from public.redline_latest_thread_event_by_phone_v1((select array_agg(contact_phone)::text[] from phones))
order by contact_phone;
