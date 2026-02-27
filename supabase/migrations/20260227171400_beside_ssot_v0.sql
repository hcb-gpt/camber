-- Beside SSOT Direct-Read Schema v0 (parallel ingest + Zapier comparison)
--
-- Purpose:
-- - Enable *parallel* ingestion from Beside local SSOT (db.sqlite + cached_rooms.json).
-- - Preserve Beside-native identifiers for deterministic thread replay in Redline.
-- - Provide join/coverage fields to compare direct-read vs Zapier/OpenPhone fallback.
--
-- Core identifiers (Beside):
-- - thread/room: prv_*
-- - message:     msg_*
-- - call:        cll_*
-- - voicemail:   vno_*
--
-- Notes:
-- - These tables are additive and do not replace existing ingest yet.
-- - RLS is not enabled; reads should be via service_role / edge functions.

begin;
-- -------------------------
-- 1) Threads (Rooms/Chats)
-- -------------------------
create table if not exists public.beside_threads (
  beside_room_id text primary key, -- prv_*

  -- Cursor state for pagination/completeness checks
  cursor_before text,
  cursor_after text,
  stream_cursor text,

  -- Thread metadata (often privateChat/inbox-backed)
  inbox_id text, -- ibx_*
  participants_user_ids text[] not null default '{}'::text[],

  -- Contact join (for Redline + comparison vs Zapier)
  contact_phone_e164 text,
  contact_id uuid references public.contacts(id),

  -- Normalized timestamps
  updated_at_utc timestamptz,

  -- Ingest provenance
  source text not null default 'direct',
  ingested_at_utc timestamptz not null default now(),

  -- Forward-compat: store raw thread payload (e.g., chat/privateChat/inbox fragments)
  payload_json jsonb not null default '{}'::jsonb,

  constraint beside_threads_source_check
    check (source in ('direct', 'zapier'))
);
create index if not exists beside_threads_contact_id_idx
  on public.beside_threads (contact_id);
create index if not exists beside_threads_contact_phone_idx
  on public.beside_threads (contact_phone_e164);
create index if not exists beside_threads_updated_at_idx
  on public.beside_threads (updated_at_utc desc nulls last);
-- -------------------------
-- 2) Thread Events
-- -------------------------
create table if not exists public.beside_thread_events (
  beside_event_id text primary key, -- msg_* | cll_* | vno_* | cap_* | sum_*
  beside_room_id text not null references public.beside_threads(beside_room_id) on delete cascade,

  beside_event_type text not null,
  occurred_at_utc timestamptz not null,
  updated_at_utc timestamptz,

  -- Identity + direction
  direction text not null default 'unknown',
  author_user_id text,
  sender_user_id text,
  sender_inbox_id text,

  -- Display payload (optional, event-type dependent)
  text text,
  summary text,
  status integer,
  share_url text,

  -- Contact join + comparison
  contact_phone_e164 text,
  contact_id uuid references public.contacts(id),
  camber_interaction_id text, -- for calls: matches interactions/calls_raw interaction_id (cll_*)
  camber_sms_message_id uuid, -- for fallback join to public.sms_messages.id

  -- Ingest provenance
  source text not null default 'direct',
  ingested_at_utc timestamptz not null default now(),

  -- Raw row payload (full Beside row for forward-compat)
  payload_json jsonb not null default '{}'::jsonb,

  constraint beside_thread_events_type_check
    check (beside_event_type in ('message', 'call', 'voice_note', 'ai_summary', 'capture')),
  constraint beside_thread_events_direction_check
    check (direction in ('inbound', 'outbound', 'unknown')),
  constraint beside_thread_events_source_check
    check (source in ('direct', 'zapier'))
);
create index if not exists beside_thread_events_room_time_idx
  on public.beside_thread_events (beside_room_id, occurred_at_utc desc);
create index if not exists beside_thread_events_contact_time_idx
  on public.beside_thread_events (contact_id, occurred_at_utc desc);
create index if not exists beside_thread_events_source_time_idx
  on public.beside_thread_events (source, occurred_at_utc desc);
create index if not exists beside_thread_events_camber_interaction_idx
  on public.beside_thread_events (camber_interaction_id);
create index if not exists beside_thread_events_camber_sms_id_idx
  on public.beside_thread_events (camber_sms_message_id);
-- -------------------------
-- 3) Transcript Turns
-- -------------------------
create table if not exists public.beside_transcripts (
  entity_id text primary key, -- cll_* | vno_*
  beside_room_id text references public.beside_threads(beside_room_id) on delete set null,

  generated_at_utc timestamptz,
  updated_at_utc timestamptz,

  speaker_ids text[] not null default '{}'::text[],
  items_json jsonb not null default '[]'::jsonb,

  -- Ingest provenance
  source text not null default 'direct',
  ingested_at_utc timestamptz not null default now(),

  payload_json jsonb not null default '{}'::jsonb,

  constraint beside_transcripts_source_check
    check (source in ('direct', 'zapier'))
);
create index if not exists beside_transcripts_room_idx
  on public.beside_transcripts (beside_room_id);
create index if not exists beside_transcripts_updated_at_idx
  on public.beside_transcripts (updated_at_utc desc nulls last);
-- -------------------------
-- Grants (service_role for edge functions / ops)
-- -------------------------
grant select, insert, update, delete on public.beside_threads to service_role;
grant select, insert, update, delete on public.beside_thread_events to service_role;
grant select, insert, update, delete on public.beside_transcripts to service_role;
comment on table public.beside_threads is
  'Beside direct-read thread index (parallel ingest). Stores Beside room_id (prv_*) plus cursors for completeness and contact join fields for Redline coverage comparison.';
comment on table public.beside_thread_events is
  'Beside direct-read event ledger (parallel ingest). Stores Beside-native ids (msg_*/cll_*/vno_*) and normalized occurred_at_utc for deterministic thread replay; includes optional join fields for Zapier fallback comparisons.';
comment on table public.beside_transcripts is
  'Beside transcript turns for calls/voicemails. Preserves speaker_ids + items_json for pixel-parity rendering; additive to CAMBER call transcript text fields.';
commit;
