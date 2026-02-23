-- Operator-facing attribution "why" view.
-- Uses live evidence columns (reasoning + anchors + evidence_tier).
-- matched_terms/match_positions are intentionally excluded (dead columns).

CREATE OR REPLACE VIEW public.v_operator_span_why AS
SELECT
  cs.interaction_id,
  cs.span_index,
  sa.span_id,
  sa.decision,
  sa.confidence,
  sa.evidence_tier,
  p.name AS assigned_project,
  ap.name AS applied_project,
  sa.attribution_source,
  left(sa.reasoning, 200) AS reasoning_summary,
  sa.anchors -> 0 ->> 'text' AS anchor_1_text,
  sa.anchors -> 0 ->> 'quote' AS anchor_1_quote,
  sa.anchors -> 0 ->> 'match_type' AS anchor_1_type,
  sa.anchors -> 1 ->> 'text' AS anchor_2_text,
  sa.anchors -> 1 ->> 'quote' AS anchor_2_quote,
  sa.anchors -> 1 ->> 'match_type' AS anchor_2_type,
  sa.anchors -> 2 ->> 'text' AS anchor_3_text,
  sa.anchors -> 2 ->> 'quote' AS anchor_3_quote,
  sa.anchors -> 2 ->> 'match_type' AS anchor_3_type,
  jsonb_array_length(COALESCE(sa.anchors, '[]'::jsonb)) AS total_anchors,
  sa.needs_review,
  sa.attributed_at
FROM public.span_attributions sa
JOIN public.conversation_spans cs ON cs.id = sa.span_id
LEFT JOIN public.projects p ON p.id = sa.project_id
LEFT JOIN public.projects ap ON ap.id = sa.applied_project_id;
