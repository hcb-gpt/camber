-- Migration: Enforce single-project invariant (P0-4)
-- Rule: 1-project contact => 0 unassigned spans / 0 pending review_queue items
--
-- Components:
--   1) enforce_single_project_invariant(contact_id) — sweep function
--   2) Trigger on project_contacts — reactive enforcement on assignment changes
--   3) v_single_project_invariant_violations — monitoring view
--   4) Backfill sweep for any existing violations

begin;

-- ============================================================
-- 1) Sweep function: auto-assign all unassigned work for a
--    single-project contact.
-- ============================================================
create or replace function public.enforce_single_project_invariant(p_contact_id uuid)
returns void
language plpgsql
as $$
declare
  v_project_id uuid;
begin
  v_project_id := public.get_contact_anchored_project_id(p_contact_id);

  if v_project_id is null then
    return; -- not single-project, nothing to enforce
  end if;

  -- 1a) Auto-assign unassigned span_attributions.
  --     Respects human locks (attribution_lock = 'human' is never overridden).
  --     The AFTER UPDATE trigger trg_span_attr_close_review_queue will
  --     cascade-close corresponding review_queue items.
  update public.span_attributions sa
  set applied_project_id = v_project_id,
      needs_review       = false,
      decision           = 'assign',
      confidence         = 1.0,
      attribution_source = 'anchored_contact',
      reasoning          = coalesce(reasoning || ' ', '')
                           || '(Enforced: single-project invariant sweep)'
  from public.conversation_spans s
  join public.interactions i on i.interaction_id = s.interaction_id
  where sa.span_id = s.id
    and sa.applied_project_id is null
    and (sa.attribution_lock is distinct from 'human')
    and i.contact_id = p_contact_id;

  -- 1b) Auto-assign interactions.project_id
  update public.interactions
  set project_id = v_project_id
  where contact_id = p_contact_id
    and project_id is null;

  -- 1c) Close any remaining pending review_queue items that the
  --     span_attributions cascade didn't catch (e.g. orphaned items).
  update public.review_queue rq
  set status            = 'resolved',
      resolution_action = 'auto_promote',
      resolution_notes  = 'auto-closed: single-project invariant enforcement',
      resolved_at       = now(),
      resolved_by       = 'fn:enforce_single_project_invariant'
  from public.conversation_spans s
  join public.interactions i on i.interaction_id = s.interaction_id
  where rq.span_id = s.id
    and rq.status = 'pending'
    and i.contact_id = p_contact_id;
end;
$$;

comment on function public.enforce_single_project_invariant(uuid) is
  'Sweeps all unassigned spans / pending review_queue items for a single-project contact. No-op if contact has != 1 project.';

-- ============================================================
-- 2) Trigger on project_contacts: when a contact's assignment
--    state changes, re-enforce the invariant.
-- ============================================================
create or replace function public.trg_enforce_single_project_on_pc_change_fn()
returns trigger
language plpgsql
as $$
declare
  v_contact_id uuid;
begin
  -- Determine which contact to sweep
  if TG_OP = 'DELETE' then
    v_contact_id := OLD.contact_id;
  else
    v_contact_id := NEW.contact_id;
  end if;

  -- If contact_id changed on UPDATE, also sweep the old contact
  if TG_OP = 'UPDATE' and OLD.contact_id is distinct from NEW.contact_id then
    perform public.enforce_single_project_invariant(OLD.contact_id);
  end if;

  perform public.enforce_single_project_invariant(v_contact_id);

  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_enforce_single_project_invariant on public.project_contacts;
drop trigger if exists trg_enforce_single_project_invariant_del on public.project_contacts;

-- Split into two triggers: PG doesn't allow UPDATE OF with DELETE in one trigger
create trigger trg_enforce_single_project_invariant
  after insert or update of contact_id, project_id, is_active
  on public.project_contacts
  for each row
  execute function public.trg_enforce_single_project_on_pc_change_fn();

create trigger trg_enforce_single_project_invariant_del
  after delete
  on public.project_contacts
  for each row
  execute function public.trg_enforce_single_project_on_pc_change_fn();

-- ============================================================
-- 3) Monitoring view: detect invariant violations.
-- ============================================================
create or replace view public.v_single_project_invariant_violations as
with anchored_contacts as (
  -- Contacts with exactly one active project
  select
    pc.contact_id,
    min(pc.project_id) as anchored_project_id
  from public.project_contacts pc
  where pc.is_active = true
  group by pc.contact_id
  having count(distinct pc.project_id) = 1
),
unassigned_spans as (
  select
    ac.contact_id,
    ac.anchored_project_id,
    sa.id as span_attribution_id,
    sa.span_id,
    'unassigned_span' as violation_type
  from anchored_contacts ac
  join public.interactions i on i.contact_id = ac.contact_id
  join public.conversation_spans s on s.interaction_id = i.interaction_id
    and s.is_superseded = false
  join public.span_attributions sa on sa.span_id = s.id
  where sa.applied_project_id is null
    and sa.attribution_lock is distinct from 'human'
),
pending_review as (
  select
    ac.contact_id,
    ac.anchored_project_id,
    rq.id as review_queue_id,
    rq.span_id,
    'pending_review' as violation_type
  from anchored_contacts ac
  join public.interactions i on i.contact_id = ac.contact_id
  join public.conversation_spans s on s.interaction_id = i.interaction_id
    and s.is_superseded = false
  join public.review_queue rq on rq.span_id = s.id
  where rq.status = 'pending'
)
select contact_id, anchored_project_id, span_attribution_id as violation_ref_id,
       span_id, violation_type
from unassigned_spans
union all
select contact_id, anchored_project_id, review_queue_id as violation_ref_id,
       span_id, violation_type
from pending_review;

comment on view public.v_single_project_invariant_violations is
  'Rows here mean the single-project invariant is violated: anchored (1-project) contacts with unassigned spans or pending review_queue items.';

grant select on public.v_single_project_invariant_violations to anon;

-- ============================================================
-- 4) Backfill: sweep all anchored contacts that still have
--    violations. Uses the same function the trigger calls.
-- ============================================================
do $$
declare
  r record;
begin
  for r in
    select distinct contact_id
    from public.v_single_project_invariant_violations
  loop
    perform public.enforce_single_project_invariant(r.contact_id);
  end loop;
end;
$$;

commit;
