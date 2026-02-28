-- Single-project invariant enforcement
-- Rule: When a contact has exactly 1 project in project_contacts,
-- all their span_attributions and review_queue items must be auto-assigned.
--
-- Trigger A: BEFORE INSERT on review_queue — auto-resolve if contact is anchored
--   to exactly 1 project (prevents orphan review_queue items for single-project contacts).
-- Trigger B: AFTER INSERT/UPDATE on span_attributions — auto-resolve existing
--   pending review_queue items when a span gets attributed to the contact's sole project.

-- ============================================================
-- Trigger A: Guard review_queue inserts for anchored contacts
-- ============================================================
CREATE OR REPLACE FUNCTION trg_review_queue_single_project_guard()
RETURNS TRIGGER AS $$
DECLARE
  v_contact_id uuid;
  v_project_count int;
  v_sole_project_id uuid;
BEGIN
  -- Resolve contact_id from the interaction
  IF NEW.interaction_id IS NOT NULL THEN
    SELECT i.contact_id INTO v_contact_id
    FROM interactions i
    WHERE i.id = NEW.interaction_id;
  END IF;

  -- If no contact, let insert proceed (nothing to enforce)
  IF v_contact_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Count active projects for this contact
  SELECT count(*), min(project_id)
  INTO v_project_count, v_sole_project_id
  FROM project_contacts
  WHERE contact_id = v_contact_id
    AND is_active = true;

  -- If exactly 1 project, auto-resolve instead of leaving pending
  IF v_project_count = 1 AND v_sole_project_id IS NOT NULL THEN
    NEW.status := 'resolved';
    NEW.resolved_at := now();
    NEW.resolved_by := 'single_project_invariant';
    NEW.resolution_action := 'confirmed';
    NEW.resolution_notes := format(
      'Auto-resolved: contact has single project %s',
      v_sole_project_id
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_review_queue_single_project_guard ON review_queue;
CREATE TRIGGER trg_review_queue_single_project_guard
  BEFORE INSERT ON review_queue
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION trg_review_queue_single_project_guard();

-- ============================================================
-- Trigger B: Auto-resolve orphan review_queue on span attribution
-- ============================================================
CREATE OR REPLACE FUNCTION trg_span_attribution_resolve_orphans()
RETURNS TRIGGER AS $$
DECLARE
  v_contact_id uuid;
  v_project_count int;
  v_sole_project_id uuid;
  v_interaction_id uuid;
  v_resolved_count int;
BEGIN
  -- Get the interaction_id for this span
  SELECT cs.interaction_id INTO v_interaction_id
  FROM conversation_spans cs
  WHERE cs.id = NEW.span_id;

  IF v_interaction_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get the contact for this interaction
  SELECT i.contact_id INTO v_contact_id
  FROM interactions i
  WHERE i.id = v_interaction_id;

  IF v_contact_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Check if single-project contact
  SELECT count(*), min(project_id)
  INTO v_project_count, v_sole_project_id
  FROM project_contacts
  WHERE contact_id = v_contact_id
    AND is_active = true;

  IF v_project_count = 1 AND v_sole_project_id IS NOT NULL THEN
    -- Resolve any pending review_queue items for this interaction
    UPDATE review_queue
    SET status = 'resolved',
        resolved_at = now(),
        resolved_by = 'single_project_invariant',
        resolution_action = 'confirmed',
        resolution_notes = format(
          'Auto-resolved on attribution: contact has single project %s',
          v_sole_project_id
        )
    WHERE interaction_id = v_interaction_id
      AND status = 'pending';

    GET DIAGNOSTICS v_resolved_count = ROW_COUNT;
    -- Log only if we actually resolved something (debug aid)
    IF v_resolved_count > 0 THEN
      RAISE LOG 'single_project_invariant: auto-resolved % review_queue items for interaction % (project %)',
        v_resolved_count, v_interaction_id, v_sole_project_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_span_attribution_resolve_orphans ON span_attributions;
CREATE TRIGGER trg_span_attribution_resolve_orphans
  AFTER INSERT OR UPDATE ON span_attributions
  FOR EACH ROW
  EXECUTE FUNCTION trg_span_attribution_resolve_orphans();

COMMENT ON FUNCTION trg_review_queue_single_project_guard() IS
  'P0-4: Prevents orphan pending review_queue items for contacts with exactly 1 project.';
COMMENT ON FUNCTION trg_span_attribution_resolve_orphans() IS
  'P0-4: Auto-resolves pending review_queue items when span attributed to single-project contact.';
