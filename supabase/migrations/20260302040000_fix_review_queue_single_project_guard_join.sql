-- Fix review_queue single-project invariant trigger join key.
--
-- Bug:
--   trg_review_queue_single_project_guard compared interactions.id (uuid)
--   to review_queue.interaction_id (text), raising:
--     operator does not exist: uuid = text
--
-- Impact:
--   segment-call coverage-gap backfill (review_queue insert) fails, leaving
--   uncovered spans with needs_review=true but no review_queue row.

begin;

create or replace function public.trg_review_queue_single_project_guard()
returns trigger
language plpgsql
as $$
declare
  v_contact_id uuid;
  v_project_count int;
  v_sole_project_id uuid;
begin
  -- review_queue.interaction_id is TEXT; join via interactions.interaction_id
  if new.interaction_id is not null then
    select i.contact_id into v_contact_id
    from public.interactions i
    where i.interaction_id = new.interaction_id;
  end if;

  -- If no contact, let insert proceed (nothing to enforce)
  if v_contact_id is null then
    return new;
  end if;

  -- Count active projects for this contact
  select count(*) into v_project_count
  from public.project_contacts
  where contact_id = v_contact_id
    and is_active = true;

  -- If exactly 1 project, auto-resolve instead of leaving pending
  if v_project_count = 1 then
    select project_id into v_sole_project_id
    from public.project_contacts
    where contact_id = v_contact_id
      and is_active = true
    limit 1;

    if v_sole_project_id is not null then
      new.status := 'resolved';
      new.resolved_at := now();
      new.resolved_by := 'single_project_invariant';
      new.resolution_action := 'confirmed';
      new.resolution_notes := format(
        'Auto-resolved: contact has single project %s',
        v_sole_project_id
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_review_queue_single_project_guard on public.review_queue;
create trigger trg_review_queue_single_project_guard
  before insert on public.review_queue
  for each row
  when (new.status = 'pending')
  execute function public.trg_review_queue_single_project_guard();

commit;
