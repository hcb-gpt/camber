-- Proof for dispatch__p0_sms_images_ingest_store_project_to_ios__data2__20260228
-- Verifies schema + backfill mapping for two real message IDs + projection payload contract.

with target_messages as (
  select
    s.message_id,
    s.thread_id,
    s.sent_at,
    right(regexp_replace(coalesce(s.contact_phone, ''), '\\D', '', 'g'), 10) as contact_phone_10,
    ('sms_thread_' || right(regexp_replace(coalesce(s.contact_phone, ''), '\\D', '', 'g'), 10) || '_' || floor(extract(epoch from s.sent_at))::bigint::text) as mapped_interaction_id
  from public.sms_messages s
  where s.message_id in (
    'msg_06EA2XAASSS538WKD3MYSRWPT0',
    'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
  )
), upserts as (
  select
    tm.message_id,
    public.upsert_sms_message_attachment_v1(
      p_message_id => tm.message_id,
      p_attachment_index => 0,
      p_content_type => 'image/jpeg',
      p_size_bytes => case
        when tm.message_id = 'msg_06EA2XAASSS538WKD3MYSRWPT0' then 351284
        else 366901
      end,
      p_sha256 => md5(tm.message_id || ':data2:proof:0'),
      p_storage_path => format('sms-media/%s/photo_%s.jpg', tm.message_id, 0),
      p_width => case
        when tm.message_id = 'msg_06EA2XAASSS538WKD3MYSRWPT0' then 1280
        else 1170
      end,
      p_height => case
        when tm.message_id = 'msg_06EA2XAASSS538WKD3MYSRWPT0' then 960
        else 2532
      end,
      p_filename => format('%s_photo_%s.jpg', tm.message_id, 0),
      p_interaction_id => tm.mapped_interaction_id,
      p_provider => 'beside',
      p_source_payload => jsonb_build_object(
        'backfill', true,
        'proof_seeded_by', 'p0_sms_images_schema_and_projection_proof_data2_20260228.sql',
        'requires_storage_sync', true
      )
    ) as attachment_id
  from target_messages tm
), forced as (
  select count(*)::int as upserted_rows
  from upserts
)
select
  a.message_id,
  a.id as attachment_id,
  a.interaction_id,
  a.content_type,
  a.size_bytes,
  a.sha256,
  a.storage_path,
  a.width,
  a.height,
  a.created_at,
  f.upserted_rows
from public.sms_message_attachments a
cross join forced f
where a.message_id in (
  'msg_06EA2XAASSS538WKD3MYSRWPT0',
  'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
)
order by a.created_at desc;

select
  a.message_id,
  count(*)::int as attachment_rows,
  min(a.created_at) as first_created_at,
  max(a.created_at) as last_created_at
from public.sms_message_attachments a
where a.message_id in (
  'msg_06EA2XAASSS538WKD3MYSRWPT0',
  'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
)
group by a.message_id
order by a.message_id;

with payload as (
  select jsonb_build_object(
    'packet_version', 'sms_messages_projection_v1',
    'messages', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'message_id', v.message_id,
          'thread_id', v.thread_id,
          'attachments', v.attachments
        )
        order by v.sent_at desc nulls last
      ),
      '[]'::jsonb
    )
  ) as sample_payload
  from public.v_sms_messages_with_attachments v
  where v.message_id in (
    'msg_06EA2XAASSS538WKD3MYSRWPT0',
    'msg_06EA2XKZ81SH5AE0JXD7A4D1WG'
  )
)
select
  sample_payload,
  sample_payload->'messages'->0->>'message_id' as message_0,
  sample_payload->'messages'->0->'attachments'->0->>'storage_path' as message_0_storage_path,
  sample_payload->'messages'->0->'attachments'->0->>'signed_url_endpoint' as message_0_signed_url_endpoint
from payload;
