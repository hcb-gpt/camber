begin;

create table if not exists public.sms_message_attachments (
  id uuid primary key default gen_random_uuid(),
  message_id text not null references public.sms_messages(message_id) on delete cascade,
  interaction_id text,
  attachment_index integer not null default 0 check (attachment_index >= 0),
  content_type text not null,
  size_bytes bigint,
  sha256 text,
  storage_path text not null,
  width integer,
  height integer,
  filename text,
  provider text not null default 'beside',
  source_payload jsonb not null default '{}'::jsonb,
  captured_at_utc timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sms_message_attachments_size_nonnegative
    check (size_bytes is null or size_bytes >= 0),
  constraint sms_message_attachments_width_nonnegative
    check (width is null or width >= 0),
  constraint sms_message_attachments_height_nonnegative
    check (height is null or height >= 0)
);

create unique index if not exists uq_sms_message_attachments_message_attachment_index
  on public.sms_message_attachments (message_id, attachment_index);

create index if not exists idx_sms_message_attachments_interaction_id
  on public.sms_message_attachments (interaction_id);

create index if not exists idx_sms_message_attachments_storage_path
  on public.sms_message_attachments (storage_path);

create index if not exists idx_sms_message_attachments_created_at
  on public.sms_message_attachments (created_at desc);

create or replace function public.trg_set_sms_message_attachments_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_set_sms_message_attachments_updated_at on public.sms_message_attachments;
create trigger trg_set_sms_message_attachments_updated_at
before update on public.sms_message_attachments
for each row execute function public.trg_set_sms_message_attachments_updated_at();

create or replace function public.upsert_sms_message_attachment_v1(
  p_message_id text,
  p_attachment_index integer default 0,
  p_content_type text default 'application/octet-stream',
  p_size_bytes bigint default null,
  p_sha256 text default null,
  p_storage_path text default null,
  p_width integer default null,
  p_height integer default null,
  p_filename text default null,
  p_interaction_id text default null,
  p_provider text default 'beside',
  p_source_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_attachment_index integer := greatest(coalesce(p_attachment_index, 0), 0);
  v_storage_path text := coalesce(
    nullif(trim(p_storage_path), ''),
    format('sms-media/%s/%s', p_message_id, greatest(coalesce(p_attachment_index, 0), 0))
  );
begin
  if p_message_id is null or nullif(trim(p_message_id), '') is null then
    raise exception 'p_message_id is required';
  end if;

  if v_storage_path is null or nullif(trim(v_storage_path), '') is null then
    raise exception 'storage_path must be non-empty';
  end if;

  insert into public.sms_message_attachments (
    message_id,
    interaction_id,
    attachment_index,
    content_type,
    size_bytes,
    sha256,
    storage_path,
    width,
    height,
    filename,
    provider,
    source_payload,
    captured_at_utc
  )
  values (
    p_message_id,
    p_interaction_id,
    v_attachment_index,
    coalesce(nullif(trim(p_content_type), ''), 'application/octet-stream'),
    p_size_bytes,
    p_sha256,
    v_storage_path,
    p_width,
    p_height,
    p_filename,
    coalesce(nullif(trim(p_provider), ''), 'beside'),
    coalesce(p_source_payload, '{}'::jsonb),
    now()
  )
  on conflict (message_id, attachment_index)
  do update
     set interaction_id = coalesce(excluded.interaction_id, public.sms_message_attachments.interaction_id),
         content_type = coalesce(excluded.content_type, public.sms_message_attachments.content_type),
         size_bytes = coalesce(excluded.size_bytes, public.sms_message_attachments.size_bytes),
         sha256 = coalesce(excluded.sha256, public.sms_message_attachments.sha256),
         storage_path = coalesce(excluded.storage_path, public.sms_message_attachments.storage_path),
         width = coalesce(excluded.width, public.sms_message_attachments.width),
         height = coalesce(excluded.height, public.sms_message_attachments.height),
         filename = coalesce(excluded.filename, public.sms_message_attachments.filename),
         provider = coalesce(excluded.provider, public.sms_message_attachments.provider),
         source_payload = public.sms_message_attachments.source_payload || coalesce(excluded.source_payload, '{}'::jsonb),
         captured_at_utc = coalesce(excluded.captured_at_utc, public.sms_message_attachments.captured_at_utc)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace view public.v_sms_messages_with_attachments as
select
  s.id as sms_id,
  s.message_id,
  s.thread_id,
  s.sent_at,
  s.direction,
  s.contact_name,
  s.contact_phone,
  s.content,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'attachment_id', a.id,
        'attachment_index', a.attachment_index,
        'content_type', a.content_type,
        'size_bytes', a.size_bytes,
        'sha256', a.sha256,
        'storage_path', a.storage_path,
        'width', a.width,
        'height', a.height,
        'filename', a.filename,
        'provider', a.provider,
        'signed_url_endpoint', format('/functions/v1/sms-attachment-signed-url?attachment_id=%s&ttl_seconds=900', a.id)
      )
      order by a.attachment_index asc
    ) filter (where a.id is not null),
    '[]'::jsonb
  ) as attachments
from public.sms_messages s
left join public.sms_message_attachments a
  on a.message_id = s.message_id
group by
  s.id,
  s.message_id,
  s.thread_id,
  s.sent_at,
  s.direction,
  s.contact_name,
  s.contact_phone,
  s.content;

create or replace function public.sms_messages_projection_v1(
  p_thread_id text default null,
  p_contact_phone text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
set search_path = public
as $$
with base as (
  select
    v.sms_id,
    v.message_id,
    v.thread_id,
    v.sent_at,
    v.direction,
    v.contact_name,
    v.contact_phone,
    v.content,
    v.attachments
  from public.v_sms_messages_with_attachments v
  where (p_thread_id is null or v.thread_id = p_thread_id)
    and (
      p_contact_phone is null
      or right(regexp_replace(coalesce(v.contact_phone, ''), '\\D', '', 'g'), 10) =
         right(regexp_replace(coalesce(p_contact_phone, ''), '\\D', '', 'g'), 10)
    )
  order by v.sent_at desc nulls last, v.sms_id desc
  limit greatest(1, least(coalesce(p_limit, 100), 500))
)
select jsonb_build_object(
  'packet_version', 'sms_messages_projection_v1',
  'generated_at_utc', now(),
  'filters', jsonb_build_object(
    'thread_id', p_thread_id,
    'contact_phone', p_contact_phone,
    'limit', greatest(1, least(coalesce(p_limit, 100), 500))
  ),
  'messages',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'sms_id', b.sms_id,
          'message_id', b.message_id,
          'thread_id', b.thread_id,
          'sent_at', b.sent_at,
          'direction', b.direction,
          'contact_name', b.contact_name,
          'contact_phone', b.contact_phone,
          'content', b.content,
          'attachments', b.attachments
        )
        order by b.sent_at desc nulls last, b.sms_id desc
      ),
      '[]'::jsonb
    )
)
from base b;
$$;

comment on table public.sms_message_attachments is
  'Canonical SMS attachment metadata store with stable storage_path for read-time signed URL generation.';

comment on view public.v_sms_messages_with_attachments is
  'Message projection with attachments[] objects including stable storage_path and signed_url_endpoint contract.';

comment on function public.upsert_sms_message_attachment_v1(text, integer, text, bigint, text, text, integer, integer, text, text, text, jsonb) is
  'Idempotent attachment upsert keyed by (message_id, attachment_index) for ingest/backfill flows.';

comment on function public.sms_messages_projection_v1(text, text, integer) is
  'Returns packet JSON with messages[].attachments[] for API projection contract.';

grant select, insert, update on public.sms_message_attachments to service_role;
grant select on public.sms_message_attachments to authenticated, anon;
grant select on public.v_sms_messages_with_attachments to authenticated, anon, service_role;
grant execute on function public.upsert_sms_message_attachment_v1(text, integer, text, bigint, text, text, integer, integer, text, text, text, jsonb)
  to authenticated, anon, service_role;
grant execute on function public.sms_messages_projection_v1(text, text, integer)
  to authenticated, anon, service_role;

commit;
