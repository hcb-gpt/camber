-- Guardrail: pending review_queue items must have module set (routing dimension).
--
-- Notes:
-- - In production, this guardrail may already exist (migration drift). This migration
--   is written to be idempotent and safe to apply multiple times.
-- - We avoid setting a DEFAULT to prevent silently masking writer bugs. Writers
--   should set module explicitly (e.g., ai-router sets module='attribution').

begin;

-- Ensure column exists (safe for drifted environments).
alter table public.review_queue
  add column if not exists module text;

-- Backfill: make existing pending NULL-module rows routable.
-- (Expected to primarily affect historical ai-router inserts.)
update public.review_queue
set module = 'attribution'
where status = 'pending'
  and module is null;

-- Enforce: module required for pending rows.
do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'review_queue'
      and c.conname = 'review_queue_pending_module_not_null_chk'
  ) then
    alter table public.review_queue
      add constraint review_queue_pending_module_not_null_chk
      check ((status <> 'pending') or (module is not null));
  end if;
end;
$$;

commit;

