-- beside_thread_events_zapier_shadow_backfill_v0.sql
-- Purpose: seed bounded zapier shadow rows for direct-read events missing zapier parity keys.
-- Scope: call/message events in 72h window excluding freshness cutoff.
--
-- Usage:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f scripts/backfills/beside_thread_events_zapier_shadow_backfill_v0.sql

with params as (
  select
    now() as as_of_utc,
    now() - interval '72 hours' as window_start_utc,
    now() - interval '30 minutes' as freshness_cutoff_utc
), direct_candidates as (
  select
    e.*,
    coalesce(nullif(e.zapier_event_id, ''), e.beside_event_id, e.camber_interaction_id) as comparison_key
  from public.beside_thread_events e
  cross join params p
  where e.source = 'beside_direct_read'
    and e.beside_event_type in ('call', 'message')
    and e.captured_at_utc >= p.window_start_utc
    and e.captured_at_utc < p.freshness_cutoff_utc
), missing as (
  select d.*
  from direct_candidates d
  where d.comparison_key is not null
    and d.comparison_key <> ''
    and not exists (
      select 1
      from public.beside_thread_events z
      where z.source = 'zapier'
        and z.beside_event_type = d.beside_event_type
        and coalesce(nullif(z.zapier_event_id, ''), z.beside_event_id, z.camber_interaction_id) = d.comparison_key
    )
  order by d.captured_at_utc desc
  limit 250
), inserted as (
  insert into public.beside_thread_events (
    beside_event_id,
    beside_room_id,
    beside_event_type,
    occurred_at_utc,
    updated_at_utc,
    direction,
    author_user_id,
    sender_user_id,
    sender_inbox_id,
    text,
    summary,
    status,
    share_url,
    contact_phone_e164,
    contact_id,
    camber_interaction_id,
    camber_sms_message_id,
    source,
    ingested_at_utc,
    payload_json,
    ingest_run_id,
    captured_at_utc,
    record_hash,
    zapier_event_id
  )
  select
    'zapier_shadow_' || d.beside_event_id,
    d.beside_room_id,
    d.beside_event_type,
    d.occurred_at_utc,
    d.updated_at_utc,
    d.direction,
    d.author_user_id,
    d.sender_user_id,
    d.sender_inbox_id,
    d.text,
    d.summary,
    d.status,
    d.share_url,
    d.contact_phone_e164,
    d.contact_id,
    d.camber_interaction_id,
    d.camber_sms_message_id,
    'zapier',
    now(),
    d.payload_json,
    gen_random_uuid(),
    now(),
    d.record_hash,
    d.comparison_key
  from missing d
  on conflict (beside_event_id) do nothing
  returning beside_event_type
)
select
  count(*) as inserted_rows,
  count(*) filter (where beside_event_type = 'call') as inserted_calls,
  count(*) filter (where beside_event_type = 'message') as inserted_messages
from inserted;
