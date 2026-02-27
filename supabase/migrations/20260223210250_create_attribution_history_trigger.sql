CREATE OR REPLACE FUNCTION trg_attribution_history_on_change()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.attribution_history (
    span_id, attribution_id, project_id, confidence, decision,
    applied_project_id, gatekeeper_reason, gatekeeper_details,
    prompt_version, model_id, pipeline_versions, attribution_source,
    evidence_tier, reasoning, anchors, attribution_lock,
    attributed_by, attributed_at, needs_review, candidates_snapshot,
    action, actor, change_summary
  ) VALUES (
    NEW.span_id, NEW.id, NEW.project_id, NEW.confidence, NEW.decision,
    NEW.applied_project_id, NEW.gatekeeper_reason, NEW.gatekeeper_details,
    NEW.prompt_version, NEW.model_id, NEW.pipeline_versions, NEW.attribution_source,
    NEW.evidence_tier, NEW.reasoning, NEW.anchors, NEW.attribution_lock,
    NEW.attributed_by, NEW.attributed_at, NEW.needs_review, NEW.candidates_snapshot,
    CASE
      WHEN TG_OP = 'INSERT' THEN 'create'
      WHEN NEW.attribution_source LIKE '%backfill%' THEN 'backfill'
      ELSE 'update'
    END,
    COALESCE(NEW.attributed_by, 'unknown'),
    CASE
      WHEN TG_OP = 'INSERT' THEN 'initial attribution'
      ELSE concat_ws(', ',
        CASE WHEN OLD.decision IS DISTINCT FROM NEW.decision
             THEN format('decision %s->%s', OLD.decision, NEW.decision) END,
        CASE WHEN OLD.confidence IS DISTINCT FROM NEW.confidence
             THEN format('confidence %s->%s', OLD.confidence, NEW.confidence) END,
        CASE WHEN OLD.project_id IS DISTINCT FROM NEW.project_id
             THEN 'project changed' END,
        CASE WHEN OLD.applied_project_id IS DISTINCT FROM NEW.applied_project_id
             THEN 'applied_project changed' END,
        CASE WHEN OLD.attribution_lock IS DISTINCT FROM NEW.attribution_lock
             THEN format('lock %s->%s', OLD.attribution_lock, NEW.attribution_lock) END
      )
    END
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_attribution_history
  AFTER INSERT OR UPDATE ON public.span_attributions
  FOR EACH ROW EXECUTE FUNCTION trg_attribution_history_on_change();;
