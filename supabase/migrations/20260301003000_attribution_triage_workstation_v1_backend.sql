-- Migration: Attribution Triage Workstation v1 Backend
-- Date: 2026-03-01
-- Scope: Epic 2.3 — Human-in-the-loop attribution triage
-- Components: audit table, card view, verdict function

-- 1. Audit log table for attribution verdicts
CREATE TABLE IF NOT EXISTS public.attribution_verdict_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_queue_id uuid REFERENCES public.review_queue(id),
  interaction_id text NOT NULL,
  span_id uuid,
  prior_project_id uuid REFERENCES public.projects(id),
  new_project_id uuid REFERENCES public.projects(id),
  action text NOT NULL CHECK (action IN ('accept','reject','escalate','skip')),
  reason_code text,
  note text,
  reviewer_id text NOT NULL,
  time_spent_sec numeric,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_verdict_audit_interaction ON public.attribution_verdict_audit(interaction_id);
CREATE INDEX IF NOT EXISTS idx_verdict_audit_reviewer ON public.attribution_verdict_audit(reviewer_id);
CREATE INDEX IF NOT EXISTS idx_verdict_audit_review_queue ON public.attribution_verdict_audit(review_queue_id);

ALTER TABLE public.attribution_verdict_audit ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE tablename = 'attribution_verdict_audit' AND policyname = 'Service role full access on attribution_verdict_audit'
    ) THEN
        CREATE POLICY "Service role full access on attribution_verdict_audit"
          ON public.attribution_verdict_audit FOR ALL
          TO service_role
          USING (true)
          WITH CHECK (true);
    END IF;
END $$;

-- 2. Triage card view (joins review_queue + span_attributions + projects + conversation_spans)
CREATE OR REPLACE VIEW public.v_triage_attribution_cards AS
SELECT
  rq.id AS card_id,
  rq.id AS review_queue_id,
  rq.interaction_id,
  rq.span_id,
  rq.status AS queue_status,
  rq.reasons,
  rq.reason_codes,
  rq.created_at AS queued_at,
  rq.hit_count,
  rq.undecided_count,
  sa.id AS attribution_id,
  sa.project_id AS proposed_project_id,
  p.name AS proposed_project_name,
  sa.confidence,
  sa.decision AS decision_mode,
  sa.reasoning,
  sa.attribution_source,
  sa.top_candidates,
  sa.runner_up_confidence,
  sa.candidate_count,
  sa.evidence_tier,
  sa.evidence_classification,
  sa.attribution_lock,
  sa.applied_project_id,
  sa.needs_review,
  cs.transcript_segment AS evidence_excerpt,
  cs.time_start_sec,
  cs.time_end_sec,
  cs.word_count
FROM public.review_queue rq
LEFT JOIN public.span_attributions sa ON sa.span_id = rq.span_id
LEFT JOIN public.projects p ON p.id = sa.project_id
LEFT JOIN public.conversation_spans cs ON cs.id = rq.span_id
WHERE rq.module = 'attribution';

-- 3. Atomic verdict function
-- Maps triage actions to review_queue CHECK-constrained resolution_action values:
--   accept   → manual_approve
--   reject   → manual_reject
--   escalate → manual_undecided
--   skip     → (no resolution_action change)
DROP FUNCTION IF EXISTS public.apply_attribution_verdict(uuid, text, text, uuid, text, text, numeric);
CREATE OR REPLACE FUNCTION public.apply_attribution_verdict(
  p_review_queue_id uuid,
  p_action text,
  p_reviewer_id text,
  p_chosen_project_id uuid DEFAULT NULL,
  p_reason_code text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_time_spent_sec numeric DEFAULT NULL
)
RETURNS jsonb AS $fn$
DECLARE
  v_rq record;
  v_sa record;
  v_prior_project_id uuid;
  v_result jsonb;
BEGIN
  -- Fetch review_queue item
  SELECT * INTO v_rq FROM public.review_queue WHERE id = p_review_queue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'review_queue_item_not_found');
  END IF;
  IF v_rq.status != 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_resolved', 'status', v_rq.status);
  END IF;

  -- Fetch current attribution
  SELECT project_id INTO v_prior_project_id
  FROM public.span_attributions WHERE span_id = v_rq.span_id LIMIT 1;

  -- Write audit row
  INSERT INTO public.attribution_verdict_audit
    (review_queue_id, interaction_id, span_id, prior_project_id, new_project_id, action, reason_code, note, reviewer_id, time_spent_sec)
  VALUES
    (p_review_queue_id, v_rq.interaction_id, v_rq.span_id, v_prior_project_id,
     COALESCE(p_chosen_project_id, v_prior_project_id), p_action, p_reason_code, p_note, p_reviewer_id, p_time_spent_sec);

  IF p_action = 'accept' THEN
    -- Accept: confirm proposed attribution, lock it, resolve queue
    UPDATE public.span_attributions
    SET applied_project_id = COALESCE(p_chosen_project_id, project_id),
        attribution_lock = 'human',
        needs_review = false,
        applied_at_utc = now()
    WHERE span_id = v_rq.span_id;

    UPDATE public.review_queue
    SET status = 'resolved',
        resolved_at = now(),
        resolved_by = p_reviewer_id,
        resolution_action = 'manual_approve',
        resolution_notes = p_note
    WHERE id = p_review_queue_id;

  ELSIF p_action = 'reject' THEN
    -- Reject: apply chosen alternative, lock it, resolve queue
    IF p_chosen_project_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'reject_requires_chosen_project_id');
    END IF;

    UPDATE public.span_attributions
    SET applied_project_id = p_chosen_project_id,
        attribution_lock = 'human',
        needs_review = false,
        applied_at_utc = now()
    WHERE span_id = v_rq.span_id;

    UPDATE public.review_queue
    SET status = 'resolved',
        resolved_at = now(),
        resolved_by = p_reviewer_id,
        resolution_action = 'manual_reject',
        resolution_notes = COALESCE(p_note, 'Reassigned to project ' || p_chosen_project_id::text)
    WHERE id = p_review_queue_id;

  ELSIF p_action = 'escalate' THEN
    -- Escalate: keep pending, mark undecided with reason
    IF p_reason_code IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'escalate_requires_reason_code');
    END IF;

    UPDATE public.review_queue
    SET resolution_action = 'manual_undecided',
        resolution_notes = 'ESCALATED: ' || p_reason_code || COALESCE(' — ' || p_note, ''),
        updated_at = now()
    WHERE id = p_review_queue_id;

  ELSIF p_action = 'skip' THEN
    -- Skip: no state change, just audit
    UPDATE public.review_queue
    SET updated_at = now()
    WHERE id = p_review_queue_id;

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_action', 'valid', 'accept|reject|escalate|skip');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'action', p_action,
    'review_queue_id', p_review_queue_id,
    'interaction_id', v_rq.interaction_id,
    'prior_project_id', v_prior_project_id,
    'new_project_id', COALESCE(p_chosen_project_id, v_prior_project_id)
  );
END;
$fn$ LANGUAGE plpgsql;

-- Comments
COMMENT ON TABLE public.attribution_verdict_audit IS 'Audit trail for human attribution triage verdicts — tracks every accept/reject/escalate/skip action';
COMMENT ON VIEW public.v_triage_attribution_cards IS 'Pre-joined card view for the attribution triage workstation UI';
COMMENT ON FUNCTION public.apply_attribution_verdict IS 'Atomic verdict: writes audit row, updates span_attributions lock, resolves review_queue item';
