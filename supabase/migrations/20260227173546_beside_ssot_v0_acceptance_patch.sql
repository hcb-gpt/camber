-- Beside SSOT Direct-Read Schema v0 acceptance patch
--
-- Adds diffing + run tracking fields requested by STRAT:
-- - source (zapier|beside_direct_read)
-- - ingest_run_id
-- - captured_at_utc
-- - record_hash (sha256 hex or other stable hash)
-- - optional zapier pointer ids

begin;

-- -------------------------
-- 1) Normalize source semantics
-- -------------------------

-- Threads
alter table public.beside_threads
  alter column source set default 'beside_direct_read';

update public.beside_threads
set source = 'beside_direct_read'
where source = 'direct';

alter table public.beside_threads
  drop constraint if exists beside_threads_source_check;

alter table public.beside_threads
  add constraint beside_threads_source_check
  check (source in ('beside_direct_read', 'zapier'));

-- Events
alter table public.beside_thread_events
  alter column source set default 'beside_direct_read';

update public.beside_thread_events
set source = 'beside_direct_read'
where source = 'direct';

alter table public.beside_thread_events
  drop constraint if exists beside_thread_events_source_check;

alter table public.beside_thread_events
  add constraint beside_thread_events_source_check
  check (source in ('beside_direct_read', 'zapier'));

-- Transcripts
alter table public.beside_transcripts
  alter column source set default 'beside_direct_read';

update public.beside_transcripts
set source = 'beside_direct_read'
where source = 'direct';

alter table public.beside_transcripts
  drop constraint if exists beside_transcripts_source_check;

alter table public.beside_transcripts
  add constraint beside_transcripts_source_check
  check (source in ('beside_direct_read', 'zapier'));

-- -------------------------
-- 2) Add tracking/diffing columns
-- -------------------------

-- Threads
alter table public.beside_threads
  add column if not exists ingest_run_id uuid,
  add column if not exists captured_at_utc timestamptz not null default now(),
  add column if not exists record_hash text,
  add column if not exists zapier_thread_id text;

create index if not exists beside_threads_ingest_run_idx
  on public.beside_threads (ingest_run_id);

create index if not exists beside_threads_captured_at_idx
  on public.beside_threads (captured_at_utc desc);

create index if not exists beside_threads_record_hash_idx
  on public.beside_threads (record_hash);

create index if not exists beside_threads_zapier_thread_id_idx
  on public.beside_threads (zapier_thread_id);

-- Events
alter table public.beside_thread_events
  add column if not exists ingest_run_id uuid,
  add column if not exists captured_at_utc timestamptz not null default now(),
  add column if not exists record_hash text,
  add column if not exists zapier_event_id text;

create index if not exists beside_thread_events_ingest_run_idx
  on public.beside_thread_events (ingest_run_id);

create index if not exists beside_thread_events_captured_at_idx
  on public.beside_thread_events (captured_at_utc desc);

create index if not exists beside_thread_events_record_hash_idx
  on public.beside_thread_events (record_hash);

create index if not exists beside_thread_events_zapier_event_id_idx
  on public.beside_thread_events (zapier_event_id);

-- Transcripts
alter table public.beside_transcripts
  add column if not exists ingest_run_id uuid,
  add column if not exists captured_at_utc timestamptz not null default now(),
  add column if not exists record_hash text,
  add column if not exists zapier_transcript_id text;

create index if not exists beside_transcripts_ingest_run_idx
  on public.beside_transcripts (ingest_run_id);

create index if not exists beside_transcripts_captured_at_idx
  on public.beside_transcripts (captured_at_utc desc);

create index if not exists beside_transcripts_record_hash_idx
  on public.beside_transcripts (record_hash);

create index if not exists beside_transcripts_zapier_transcript_id_idx
  on public.beside_transcripts (zapier_transcript_id);

-- -------------------------
-- 3) Grants (service_role)
-- -------------------------

grant select, insert, update, delete on public.beside_threads to service_role;
grant select, insert, update, delete on public.beside_thread_events to service_role;
grant select, insert, update, delete on public.beside_transcripts to service_role;

commit;
