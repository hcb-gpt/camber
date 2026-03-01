-- Migration: Add UNDECIDED + COMMENT support for triage card swipe gestures.
-- Adds snooze/undecided columns to review_queue + creates review_queue_notes table.
-- Based on proposed contract: scripts/sql/proposed_review_queue_undecided_comment_contract_20260228.sql

begin;

-- 1) Add undecided/snooze columns to review_queue
alter table public.review_queue
  add column if not exists snooze_until_utc timestamptz,
  add column if not exists undecided_count integer not null default 0,
  add column if not exists last_undecided_at timestamptz,
  add column if not exists attribution_type text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'review_queue_attribution_type_check'
      and conrelid = 'public.review_queue'::regclass
  ) then
    alter table public.review_queue
      add constraint review_queue_attribution_type_check
      check (
        attribution_type is null
        or attribution_type in ('project','bizdev','unknown')
      );
  end if;
end;
$$;

-- Extend resolution_action taxonomy with manual_undecided and mark_bizdev
alter table public.review_queue
  drop constraint if exists review_queue_resolution_action_check;
alter table public.review_queue
  add constraint review_queue_resolution_action_check
  check (
    resolution_action is null
    or resolution_action = any (
      array[
        'auto_dismiss',
        'auto_resolve',
        'auto_promote',
        'manual_approve',
        'manual_reject',
        'manual_attribute',
        'confirmed',
        'duplicate_dismissed',
        'dismissed',
        'manual_undecided',
        'mark_bizdev'
      ]
    )
  );

-- Indexes for snooze-aware queue queries
create index if not exists idx_review_queue_pending_unsnoozed
  on public.review_queue (created_at desc)
  where status = 'pending' and (snooze_until_utc is null or snooze_until_utc <= now());

create index if not exists idx_review_queue_pending_snoozed
  on public.review_queue (snooze_until_utc asc)
  where status = 'pending' and snooze_until_utc is not null;

-- 2) Create append-only notes table for comments and undecided reasons
create table if not exists public.review_queue_notes (
  id uuid primary key default gen_random_uuid(),
  review_queue_id uuid not null references public.review_queue(id) on delete cascade,
  note_type text not null default 'comment',
  note_text text not null,
  created_by text not null,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  check (note_type in ('comment','undecided_reason','system'))
);

create index if not exists idx_review_queue_notes_queue_created
  on public.review_queue_notes (review_queue_id, created_at desc);

-- RLS: allow anon read for iOS client, service_role for writes
alter table public.review_queue_notes enable row level security;

create policy if not exists "anon_read_review_queue_notes"
  on public.review_queue_notes for select
  to anon using (true);

create policy if not exists "service_write_review_queue_notes"
  on public.review_queue_notes for all
  to service_role using (true) with check (true);

commit;
