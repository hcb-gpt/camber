begin;

alter table public.review_queue
  alter column module set default 'attribution';

update public.review_queue
set module = 'attribution'
where status = 'pending'
  and module is null
  and context_payload ? 'prompt_version';

update public.review_queue
set module = 'attribution'
where status = 'pending'
  and module is null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.review_queue'::regclass
      and conname = 'review_queue_pending_module_not_null_chk'
  ) then
    alter table public.review_queue
      add constraint review_queue_pending_module_not_null_chk
      check (status <> 'pending' or module is not null) not valid;
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conrelid = 'public.review_queue'::regclass
      and conname = 'review_queue_pending_module_not_null_chk'
      and not convalidated
  ) then
    alter table public.review_queue
      validate constraint review_queue_pending_module_not_null_chk;
  end if;
end;
$$;

commit;
