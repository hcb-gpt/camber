begin;
-- P0 guardrail: pending review_queue rows must always be tied to a span.
-- This stops interaction-level/null-span rows (module=process_call) from
-- polluting Redline pending counts while preserving fail-open writes.

create or replace function public.guardrail_review_queue_null_span_pending()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'pending' and new.span_id is null then
    -- For inserts, swallow the write to avoid creating null-span queue rows.
    if tg_op = 'INSERT' then
      return null;
    end if;

    -- For updates, force terminal state instead of allowing pending/null.
    new.status := 'dismissed';
    new.resolved_at := coalesce(new.resolved_at, now());
    new.resolved_by := coalesce(new.resolved_by, 'guardrail:null_span_pending');
    new.resolution_action := coalesce(new.resolution_action, 'auto_dismiss');
    new.resolution_notes := coalesce(
      new.resolution_notes,
      'blocked_pending_write_without_span_id'
    );
  end if;

  return new;
end;
$$;
drop trigger if exists trg_review_queue_null_span_pending_guardrail on public.review_queue;
create trigger trg_review_queue_null_span_pending_guardrail
before insert or update on public.review_queue
for each row
execute function public.guardrail_review_queue_null_span_pending();
-- Cleanup existing bad state so UI queues are immediately corrected.
update public.review_queue
set status = 'dismissed',
    resolved_at = coalesce(resolved_at, now()),
    resolved_by = coalesce(resolved_by, 'guardrail:null_span_pending'),
    resolution_action = coalesce(resolution_action, 'auto_dismiss'),
    resolution_notes = coalesce(
      resolution_notes,
      'backfill_dismiss_pending_without_span_id'
    )
where status = 'pending'
  and span_id is null;
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.review_queue'::regclass
      and conname = 'review_queue_pending_span_id_not_null_chk'
  ) then
    alter table public.review_queue
      add constraint review_queue_pending_span_id_not_null_chk
      check (status <> 'pending' or span_id is not null) not valid;
  end if;
end;
$$;
do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conrelid = 'public.review_queue'::regclass
      and conname = 'review_queue_pending_span_id_not_null_chk'
      and not convalidated
  ) then
    alter table public.review_queue
      validate constraint review_queue_pending_span_id_not_null_chk;
  end if;
end;
$$;
commit;
