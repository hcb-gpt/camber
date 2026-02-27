-- Stopline2 validation support (Phase 1)
-- - Expand override_log.mode check to include 'reseed'
-- - Add v_interaction_primary_project aggregation view

ALTER TABLE public.override_log
  DROP CONSTRAINT IF EXISTS override_log_mode_check;
ALTER TABLE public.override_log
  ADD CONSTRAINT override_log_mode_check
  CHECK (
    mode IS NULL
    OR mode IN ('resegment_only', 'resegment_and_reroute', 'reseed')
  );
CREATE OR REPLACE VIEW public.v_interaction_primary_project AS
WITH span_project_counts AS (
  SELECT
    cs.interaction_id,
    sa.project_id,
    COUNT(*) AS span_count,
    MAX(sa.attributed_at) AS latest_attributed_at,
    COUNT(*) FILTER (WHERE sa.attribution_lock = 'human') AS human_locked_spans,
    COUNT(*) FILTER (WHERE sa.attribution_lock IS DISTINCT FROM 'human') AS nonhuman_spans
  FROM public.conversation_spans cs
  JOIN public.span_attributions sa
    ON sa.span_id = cs.id
  WHERE sa.project_id IS NOT NULL
  GROUP BY
    cs.interaction_id,
    sa.project_id
),
primary_span_project AS (
  SELECT
    interaction_id,
    project_id,
    span_count,
    latest_attributed_at,
    human_locked_spans,
    nonhuman_spans
  FROM (
    SELECT
      spc.*,
      ROW_NUMBER() OVER (
        PARTITION BY spc.interaction_id
        ORDER BY spc.span_count DESC, spc.latest_attributed_at DESC
      ) AS rn
    FROM span_project_counts spc
  ) ranked
  WHERE rn = 1
)
SELECT
  i.interaction_id,
  i.project_id AS interaction_project_id,
  COALESCE(i.project_id, psp.project_id) AS primary_project_id,
  CASE
    WHEN i.project_id IS NOT NULL THEN 'interaction'
    WHEN psp.project_id IS NOT NULL THEN 'span_attribution'
    ELSE NULL
  END AS primary_project_source,
  psp.project_id AS span_top_project_id,
  psp.span_count AS span_top_project_span_count,
  psp.human_locked_spans AS span_top_project_human_locked_spans,
  psp.nonhuman_spans AS span_top_project_model_spans,
  psp.latest_attributed_at AS span_top_project_last_attributed_at
FROM public.interactions i
LEFT JOIN primary_span_project psp
  ON psp.interaction_id = i.interaction_id;
COMMENT ON VIEW public.v_interaction_primary_project IS
  'Interaction-level project attribution fallback:
  interaction.project_id first, otherwise top span-attributed project.';
