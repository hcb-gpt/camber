-- Enforce pointer-quality for assigned span attributions.
-- If we cannot resolve a durable evidence_event for the underlying interaction,
-- we downgrade the attribution to review (no silent, unprovable assigns).

create or replace function public.enforce_span_attribution_requires_evidence_event()
returns trigger
language plpgsql
as $$
declare
  v_interaction_id text;
begin
  -- Only gate assigned attributions (operator-facing correctness)
  if new.decision = 'assign' and coalesce(new.applied_project_id, new.project_id) is not null then
    select cs.interaction_id into v_interaction_id
    from public.conversation_spans cs
    where cs.id = new.span_id;

    if v_interaction_id is null then
      new.decision := 'review';
      new.needs_review := true;
      new.applied_project_id := null;
      new.evidence_classification := coalesce(new.evidence_classification, '{}'::jsonb)
        || jsonb_build_object(
             'pointer_quality_violation', true,
             'pointer_quality_reason', 'missing_interaction_id'
           );
      return new;
    end if;

    if not exists (
      select 1
      from public.evidence_events ee
      where ee.source_type = 'call'
        and ee.source_id = v_interaction_id
    ) then
      new.decision := 'review';
      new.needs_review := true;
      new.applied_project_id := null;
      new.evidence_classification := coalesce(new.evidence_classification, '{}'::jsonb)
        || jsonb_build_object(
             'pointer_quality_violation', true,
             'pointer_quality_reason', 'missing_evidence_event'
           );
      return new;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_span_attr_requires_evidence_event on public.span_attributions;

create trigger trg_span_attr_requires_evidence_event
before insert or update on public.span_attributions
for each row
execute function public.enforce_span_attribution_requires_evidence_event();

comment on function public.enforce_span_attribution_requires_evidence_event is
'If span_attributions.decision=assign but the underlying interaction has no call evidence_event, downgrade to review and mark pointer_quality_violation in evidence_classification.';
;
