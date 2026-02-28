-- DB proof: SMS media persistence gap (DATA-2, P0)
-- Receipt target:
--   completion__p0_sms_media_persistence_plan_and_mvp__data2__20260228
--
-- Usage:
--   scripts/query.sh --file scripts/sql/p0_sms_media_missing_proof_data2_20260228.sql

\echo 'Q1) Two real sms_msg candidates that indicate photos/pictures in-message'
with candidates as (
  select
    m.message_id,
    m.thread_id,
    m.sent_at,
    m.direction,
    m.contact_phone,
    m.content
  from public.sms_messages m
  where m.sent_at >= now() - interval '14 days'
    and (
      lower(coalesce(m.content, '')) like '%picture%'
      or lower(coalesce(m.content, '')) like '%photo%'
      or lower(coalesce(m.content, '')) like '%image%'
    )
)
select
  message_id,
  thread_id,
  sent_at,
  direction,
  contact_phone,
  left(content, 220) as content_snippet
from candidates
where message_id in (
  'msg_06EA2XAASSS538WKD3MYSRWPT0',
  'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
)
order by sent_at;

\echo 'Q2) Current persistence check for those two IDs (no structured media fields)'
with target_messages as (
  select
    m.message_id,
    m.thread_id,
    m.sent_at,
    m.direction,
    m.contact_phone,
    m.content
  from public.sms_messages m
  where m.message_id in (
    'msg_06EA2XAASSS538WKD3MYSRWPT0',
    'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
  )
),
target_calls as (
  select
    c.interaction_id,
    c.event_at_utc,
    c.channel,
    c.raw_snapshot_json
  from public.calls_raw c
  where c.interaction_id in (
    'sms_msg_06EA2XAASSS538WKD3MYSRWPT0',
    'sms_msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
  )
)
select
  tm.message_id,
  tc.interaction_id as calls_raw_interaction_id,
  tm.sent_at,
  tc.event_at_utc,
  tc.channel,
  (position('\"attachment\"' in lower(tc.raw_snapshot_json::text)) > 0)::boolean as has_attachment_key,
  (position('\"attachments\"' in lower(tc.raw_snapshot_json::text)) > 0)::boolean as has_attachments_key,
  (position('\"media_url\"' in lower(tc.raw_snapshot_json::text)) > 0)::boolean as has_media_url_key,
  (position('\"image_url\"' in lower(tc.raw_snapshot_json::text)) > 0)::boolean as has_image_url_key,
  left(tm.content, 160) as content_snippet
from target_messages tm
left join target_calls tc
  on tc.interaction_id = replace(tm.message_id, 'msg_', 'sms_msg_')
order by tm.sent_at;

\echo 'Q3) Schema gap proof: no dedicated SMS attachment persistence table/columns'
select
  table_name
from information_schema.tables
where table_schema = 'public'
  and (
    table_name ilike '%sms%attach%'
    or table_name ilike '%sms%media%'
    or table_name ilike '%message%attach%'
  )
order by table_name;

select
  table_name,
  column_name
from information_schema.columns
where table_schema = 'public'
  and table_name in ('sms_messages', 'calls_raw')
  and (
    column_name ilike '%attach%'
    or column_name ilike '%media%'
    or column_name ilike '%mime%'
    or column_name ilike '%image%'
  )
order by table_name, column_name;
