-- Migration: Guard review_queue INSERT for anchored (single-project) contacts (P0-4 supplement)
--
-- Problem: ai-router race condition — the BEFORE INSERT trigger on span_attributions
-- sets needs_review=false and applied_project_id for anchored contacts, but ai-router
-- uses its stale in-memory variable to decide whether to INSERT a review_queue item.
-- This creates orphaned pending review_queue rows for already-attributed spans.
--
-- Fix: BEFORE INSERT trigger on review_queue that swallows inserts for anchored contacts.
-- Pattern matches existing guardrail_review_queue_null_span_pending().

begin;

-- ============================================================
-- 1) Guard: Prevent review_queue inserts for anchored contacts
-- ============================================================
create or replace function public.guardrail_review_queue_anchored_contact()
returns trigger
language plpgsql
as $$
declare
  v_contact_id uuid;
  v_anchored   uuid;
begin
  -- Only guard pending inserts with a span_id
  if new.status <> 'pending' or new.span_id is null then
    return new;
  end if;

  -- Resolve contact via span → interaction chain
  select i.contact_id into v_contact_id
  from public.conversation_spans cs
  join public.interactions i on i.interaction_id = cs.interaction_id
  where cs.id = new.span_id;

  if v_contact_id is not null then
    v_anchored := public.get_contact_anchored_project_id(v_contact_id);
    if v_anchored is not null then
      -- Anchored contact: swallow the insert. The span is already
      -- auto-attributed by trg_auto_assign_span_project, so a
      -- review_queue item would be an orphan.
      return null;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_review_queue_anchored_contact_guardrail on public.review_queue;

create trigger trg_review_queue_anchored_contact_guardrail
  before insert
  on public.review_queue
  for each row
  execute function public.guardrail_review_queue_anchored_contact();

-- ============================================================
-- 2) Cleanup: dismiss existing orphaned review_queue items
--    for spans that are already auto-attributed to anchored contacts.
-- ============================================================
update public.review_queue rq
set status            = 'resolved',
    resolution_action = 'auto_promote',
    resolution_notes  = 'backfill: dismissed orphaned review_queue for anchored-contact span',
    resolved_at       = now(),
    resolved_by       = 'guardrail:anchored_contact_backfill'
from public.span_attributions sa
where rq.span_id = sa.span_id
  and rq.status = 'pending'
  and sa.applied_project_id is not null
  and sa.decision = 'assign'
  and sa.attribution_source = 'anchored_contact';

commit;
