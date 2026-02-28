-- Proposed contract: UNDECIDED + COMMENT support for bootstrap-review / iOS triage.
-- Scope: schema + write contract; safe to review before apply.

begin;

-- 1) Keep pending rows durable but hide undecided items from immediate queue until snooze expires.
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

-- Add undecided resolution action (extends existing taxonomy, does not change status set).
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
        'manual_undecided',
        'mark_bizdev'
      ]
    )
  );

create index if not exists idx_review_queue_pending_unsnoozed
  on public.review_queue (created_at desc)
  where status = 'pending' and (snooze_until_utc is null or snooze_until_utc <= now());

create index if not exists idx_review_queue_pending_snoozed
  on public.review_queue (snooze_until_utc asc)
  where status = 'pending' and snooze_until_utc is not null;

-- 2) Comment history should be append-only (do not overwrite resolution_notes repeatedly).
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

-- 3) Write contract examples for bootstrap-review API.
-- POST ?action=undecided
-- {
--   "review_queue_id":"<uuid>",
--   "snooze_hours":6,
--   "comment":"Need project manager confirmation before choosing project.",
--   "user_id":"chad",
--   "source":"redline"
-- }
--
-- Server write:
--   update review_queue
--      set snooze_until_utc = now() + make_interval(hours => greatest(1, least(coalesce(:snooze_hours,6),72))),
--          undecided_count = undecided_count + 1,
--          last_undecided_at = now(),
--          resolution_action = 'manual_undecided',
--          resolved_by = coalesce(:user_id,'chad'),
--          updated_at = now()
--    where id = :review_queue_id
--      and status = 'pending';
--
--   insert into review_queue_notes(review_queue_id,note_type,note_text,created_by,metadata)
--   values (:review_queue_id,'undecided_reason',coalesce(:comment,''),coalesce(:user_id,'chad'),
--           jsonb_build_object('snooze_hours',coalesce(:snooze_hours,6),'source',coalesce(:source,'pipeline')));
--
-- POST ?action=comment
-- {
--   "review_queue_id":"<uuid>",
--   "comment":"Customer requested wait until architect callback.",
--   "user_id":"chad",
--   "source":"redline"
-- }
--
-- Server write:
--   insert into review_queue_notes(review_queue_id,note_type,note_text,created_by,metadata)
--   values (:review_queue_id,'comment',:comment,coalesce(:user_id,'chad'),
--           jsonb_build_object('source',coalesce(:source,'pipeline')));

-- 4) Queue/count contract:
-- - Actionable queue = pending rows where snooze_until_utc is null or <= now().
-- - Snoozed queue = pending rows where snooze_until_utc > now().
-- - total_pending should expose both for transparency:
--   actionable_pending_count, snoozed_pending_count, pending_total_count.

commit;

-- Rollback plan (single migration rollback):
-- 1) Drop new notes table + indexes.
-- 2) Drop snooze/undecided/attribution_type columns.
-- 3) Restore prior review_queue_resolution_action_check values.
