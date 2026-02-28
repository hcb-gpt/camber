-- View 1: Version accuracy by prompt_version × model_id × decision
CREATE OR REPLACE VIEW public.v_tuning_version_accuracy AS
SELECT
  sa.prompt_version,
  sa.model_id,
  sa.decision,
  count(*) AS total,
  count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')) AS judged,
  count(avf.verdict) FILTER (WHERE avf.verdict = 'CORRECT') AS correct,
  count(avf.verdict) FILTER (WHERE avf.verdict = 'INCORRECT') AS incorrect,
  CASE
    WHEN count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')) > 0
    THEN round(
      count(avf.verdict) FILTER (WHERE avf.verdict = 'CORRECT')::numeric /
      count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')),
      4
    )
    ELSE NULL
  END AS accuracy_rate,
  round(avg(sa.confidence), 4) AS avg_confidence,
  round(avg(sa.inference_ms), 0) AS avg_inference_ms
FROM public.span_attributions sa
LEFT JOIN public.attribution_validation_feedback avf ON avf.span_id = sa.span_id
GROUP BY sa.prompt_version, sa.model_id, sa.decision;

-- View 2: Gatekeeper analysis by confidence band × reason
CREATE OR REPLACE VIEW public.v_tuning_gatekeeper_analysis AS
WITH banded AS (
  SELECT
    sa.span_id,
    sa.gatekeeper_reason,
    sa.confidence,
    sa.decision,
    sa.applied_project_id,
    sa.attribution_lock,
    CASE
      WHEN sa.confidence < 0.25 THEN 'lt_025'
      WHEN sa.confidence < 0.40 THEN '025_040'
      WHEN sa.confidence < 0.55 THEN '040_055'
      WHEN sa.confidence < 0.70 THEN '055_070'
      WHEN sa.confidence < 0.75 THEN '070_075'
      ELSE 'ge_075'
    END AS confidence_band,
    avf.verdict,
    ol.id IS NOT NULL AS has_human_override
  FROM public.span_attributions sa
  LEFT JOIN public.attribution_validation_feedback avf ON avf.span_id = sa.span_id
  LEFT JOIN public.override_log ol ON ol.entity_id = sa.span_id
  WHERE sa.gatekeeper_reason IS NOT NULL
)
SELECT
  confidence_band,
  gatekeeper_reason,
  count(*) AS total,
  count(*) FILTER (WHERE has_human_override) AS human_overrides,
  count(*) FILTER (WHERE verdict = 'CORRECT') AS correct_verdicts,
  count(*) FILTER (WHERE verdict = 'INCORRECT') AS incorrect_verdicts,
  count(*) FILTER (WHERE gatekeeper_reason = 'needs_review' AND (has_human_override OR verdict = 'CORRECT')) AS potential_over_blocks,
  CASE
    WHEN count(*) FILTER (WHERE gatekeeper_reason = 'needs_review') > 0
    THEN round(
      count(*) FILTER (WHERE gatekeeper_reason = 'needs_review' AND (has_human_override OR verdict = 'CORRECT'))::numeric /
      count(*) FILTER (WHERE gatekeeper_reason = 'needs_review'),
      4
    )
    ELSE NULL
  END AS potential_over_block_rate
FROM banded
GROUP BY confidence_band, gatekeeper_reason
ORDER BY confidence_band, gatekeeper_reason;

-- View 3: Component impact (populated after pipeline_versions flows through)
CREATE OR REPLACE VIEW public.v_tuning_component_impact AS
SELECT
  sa.pipeline_versions->>'context_assembly' AS context_assembly_version,
  sa.pipeline_versions->>'ai_router' AS ai_router_version,
  sa.model_id,
  sa.prompt_version,
  count(*) AS total,
  count(avf.verdict) FILTER (WHERE avf.verdict = 'CORRECT') AS correct,
  count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')) AS judged,
  CASE
    WHEN count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')) > 0
    THEN round(
      count(avf.verdict) FILTER (WHERE avf.verdict = 'CORRECT')::numeric /
      count(avf.verdict) FILTER (WHERE avf.verdict IN ('CORRECT','INCORRECT')),
      4
    )
    ELSE NULL
  END AS accuracy,
  round(avg(CASE WHEN sa.decision = 'assign' THEN 1 ELSE 0 END), 4) AS assign_rate,
  round(avg(sa.confidence), 4) AS avg_confidence
FROM public.span_attributions sa
LEFT JOIN public.attribution_validation_feedback avf ON avf.span_id = sa.span_id
WHERE sa.pipeline_versions IS NOT NULL
GROUP BY
  sa.pipeline_versions->>'context_assembly',
  sa.pipeline_versions->>'ai_router',
  sa.model_id,
  sa.prompt_version;;
