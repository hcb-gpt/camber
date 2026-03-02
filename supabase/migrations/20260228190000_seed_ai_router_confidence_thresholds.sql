-- Seed ai-router confidence thresholds into inference_config
-- Moves hardcoded constants from ai-router/index.ts to the config table
-- so they can be tuned without redeployment.
--
-- Keys use the 'ai_router.' prefix to namespace them.

INSERT INTO inference_config (config_key, config_value, description, updated_by)
VALUES
  ('ai_router.threshold_auto_assign', '0.75', 'Confidence >= this for auto-assign (3-band policy v1.15.0)', 'dev-5'),
  ('ai_router.threshold_review', '0.25', 'Confidence >= this for review band (3-band policy v1.15.0)', 'dev-5'),
  ('ai_router.threshold_safe_low_assign', '0.40', 'Confidence >= this for safe-low auto-assign (extended v1.17.0)', 'dev-5'),
  ('ai_router.threshold_high_confidence_gap_assign', '0.70', 'Confidence >= this with sufficient gap for assign (extended v1.17.0)', 'dev-5'),
  ('ai_router.min_runner_up_gap', '0.20', 'Minimum confidence gap between top candidate and runner-up', 'dev-5'),
  ('ai_router.threshold_weak_review_confidence', '0.30', 'Weak review confidence threshold', 'dev-5'),
  ('ai_router.threshold_weak_review_crossref', '0.20', 'Weak review crossref threshold', 'dev-5')
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  description = EXCLUDED.description,
  updated_by = EXCLUDED.updated_by,
  updated_at = NOW();
