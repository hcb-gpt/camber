-- Auto-close review_queue items when a span attribution is promoted to an assignment.
-- Context: finding__review_queue_state_drift_on_manual_promotion

create or replace function public.trg_close_review_queue_on_promotion()
returns trigger
language plpgsql
as $$
begin
  -- Only act on promotion edge: decision becomes 'assign' AND applied_project_id is set.
  if new.decision = 'assign'
     and new.applied_project_id is not null
     and (old.decision is distinct from 'assign' or old.applied_project_id is null) then

    update public.review_queue
       set status = 'resolved',
           resolution_action = 'auto_promote',
           resolution_notes = 'auto-closed by span_attributions promotion trigger',
           resolved_at = now(),
           resolved_by = 'trigger:trg_close_review_queue_on_promotion'
     where span_id = new.span_id
       and resolved_at is null;

  end if;

  return new;
end;
$$;

drop trigger if exists trg_span_attr_close_review_queue on public.span_attributions;

create trigger trg_span_attr_close_review_queue
after update of decision, applied_project_id on public.span_attributions
for each row
execute function public.trg_close_review_queue_on_promotion();
;
