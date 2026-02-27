-- Stopline R1 hardening: score_interaction must fail when active spans are uncovered.
-- Uncovered = active span has neither span_attributions row nor pending review_queue row.

CREATE OR REPLACE FUNCTION score_interaction(
  p_interaction_id text,
  p_save_snapshot boolean DEFAULT false
)
RETURNS TABLE (
  interaction_id text,
  gen_max int,
  spans_active int,
  attributions int,
  review_items int,
  review_gap int,
  override_reseeds int,
  status text,
  created_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_gen_max int;
  v_spans_active int;
  v_attributions int;
  v_review_items int;
  v_review_gap int;
  v_override_reseeds int;
  v_uncovered_active int;
  v_status text;
  v_created_at timestamptz := now();
BEGIN
  -- Active spans
  SELECT COUNT(*)::int, COALESCE(MAX(cs.segment_generation), 0)::int
  INTO v_spans_active, v_gen_max
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id
    AND cs.is_superseded = false;

  -- Attributions for active spans
  SELECT COUNT(*)::int
  INTO v_attributions
  FROM span_attributions sa
  WHERE sa.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  );

  -- Review queue items for active spans
  SELECT COUNT(*)::int
  INTO v_review_items
  FROM review_queue rq
  WHERE rq.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  );

  -- Review gap: needs_review but no review_queue row
  SELECT COUNT(*)::int
  INTO v_review_gap
  FROM span_attributions sa
  WHERE sa.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  )
  AND (sa.decision = 'review' OR sa.needs_review = true)
  AND NOT EXISTS (
    SELECT 1 FROM review_queue rq WHERE rq.span_id = sa.span_id
  );

  -- Stopline R1 coverage gap:
  -- active span with no attribution and no pending review queue item.
  SELECT COUNT(*)::int
  INTO v_uncovered_active
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id
    AND cs.is_superseded = false
    AND NOT EXISTS (
      SELECT 1
      FROM span_attributions sa
      WHERE sa.span_id = cs.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM review_queue rq
      WHERE rq.span_id = cs.id
        AND rq.status = 'pending'
    );

  -- Override reseeds
  SELECT COUNT(*)::int
  INTO v_override_reseeds
  FROM override_log ol
  WHERE ol.interaction_id = p_interaction_id
    AND ol.entity_type = 'reseed';

  -- Determine status
  IF v_spans_active > 0 AND v_review_gap = 0 AND v_uncovered_active = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := 'FAIL';
  END IF;

  -- Optionally save snapshot
  IF p_save_snapshot THEN
    INSERT INTO pipeline_scoreboard_snapshots (
      interaction_id, gen_max, spans_active, attributions,
      review_items, review_gap, override_reseeds, status, created_at
    ) VALUES (
      p_interaction_id, v_gen_max, v_spans_active, v_attributions,
      v_review_items, v_review_gap, v_override_reseeds, v_status, v_created_at
    );
  END IF;

  RETURN QUERY SELECT
    p_interaction_id,
    v_gen_max,
    v_spans_active,
    v_attributions,
    v_review_items,
    v_review_gap,
    v_override_reseeds,
    v_status,
    v_created_at;
END;
$$;

COMMENT ON FUNCTION score_interaction(text, boolean) IS
'Returns scoreboard for an interaction. p_save_snapshot=true writes to pipeline_scoreboard_snapshots. Status fails when any active span is uncovered (no attribution and no pending review_queue row).';

-- One-time backfill for existing uncovered active spans.
-- Idempotent via review_queue span_id unique constraint.
DO $$
DECLARE
  has_module boolean;
  has_dedupe_key boolean;
  has_reason_codes boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'review_queue'
      AND column_name = 'module'
  ) INTO has_module;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'review_queue'
      AND column_name = 'dedupe_key'
  ) INTO has_dedupe_key;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'review_queue'
      AND column_name = 'reason_codes'
  ) INTO has_reason_codes;

  IF has_module AND has_dedupe_key AND has_reason_codes THEN
    INSERT INTO public.review_queue (
      span_id,
      interaction_id,
      status,
      module,
      dedupe_key,
      reason_codes,
      reasons,
      context_payload
    )
    SELECT
      cs.id,
      cs.interaction_id,
      'pending',
      'attribution',
      'coverage_gap:' || cs.id::text,
      ARRAY['coverage_gap']::text[],
      ARRAY['coverage_gap']::text[],
      jsonb_build_object(
        'source', 'migration',
        'stopline', 'r1_stopline_zero_dropped_spans',
        'reason_codes', ARRAY['coverage_gap']::text[],
        'interaction_id', cs.interaction_id,
        'span_id', cs.id::text,
        'span_index', cs.span_index,
        'transcript_snippet', left(coalesce(cs.transcript_segment, ''), 600),
        'detected_at_utc', now()
      )
    FROM public.conversation_spans cs
    WHERE cs.is_superseded = false
      AND NOT EXISTS (
        SELECT 1
        FROM public.span_attributions sa
        WHERE sa.span_id = cs.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.review_queue rq
        WHERE rq.span_id = cs.id
          AND rq.status = 'pending'
      )
    ON CONFLICT (span_id) DO UPDATE
      SET status = 'pending',
          module = excluded.module,
          dedupe_key = excluded.dedupe_key,
          reason_codes = excluded.reason_codes,
          reasons = excluded.reasons,
          context_payload = excluded.context_payload;
  ELSE
    INSERT INTO public.review_queue (
      span_id,
      interaction_id,
      status,
      reasons,
      context_payload
    )
    SELECT
      cs.id,
      cs.interaction_id,
      'pending',
      ARRAY['coverage_gap']::text[],
      jsonb_build_object(
        'source', 'migration',
        'stopline', 'r1_stopline_zero_dropped_spans',
        'reason_codes', ARRAY['coverage_gap']::text[],
        'interaction_id', cs.interaction_id,
        'span_id', cs.id::text,
        'span_index', cs.span_index,
        'transcript_snippet', left(coalesce(cs.transcript_segment, ''), 600),
        'detected_at_utc', now()
      )
    FROM public.conversation_spans cs
    WHERE cs.is_superseded = false
      AND NOT EXISTS (
        SELECT 1
        FROM public.span_attributions sa
        WHERE sa.span_id = cs.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.review_queue rq
        WHERE rq.span_id = cs.id
          AND rq.status = 'pending'
      )
    ON CONFLICT (span_id) DO UPDATE
      SET status = 'pending',
          reasons = excluded.reasons,
          context_payload = excluded.context_payload;
  END IF;
END;
$$;
