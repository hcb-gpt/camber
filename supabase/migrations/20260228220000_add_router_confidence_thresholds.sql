-- Add ai-router confidence thresholds to inference_config (item 25)
-- Keys use ai_router.* prefix to match loadThresholdsOnce() LIKE 'ai_router.%' query.
-- Fallback defaults remain in code if DB is unreachable.

INSERT INTO inference_config (config_key, config_value, description, updated_by)
VALUES
  ('ai_router.threshold_auto_assign', '0.75', 'ai-router: confidence >= this -> auto-assign decision', 'DEV'),
  ('ai_router.threshold_review', '0.25', 'ai-router: confidence >= this but < auto_assign -> review decision', 'DEV'),
  ('ai_router.threshold_safe_low_assign', '0.40', 'ai-router: minimum confidence for safe low-evidence assign path', 'DEV'),
  ('ai_router.threshold_high_confidence_gap_assign', '0.70', 'ai-router: minimum confidence for high-confidence gap promotion', 'DEV'),
  ('ai_router.min_runner_up_gap', '0.20', 'ai-router: minimum gap between top-2 candidates for gap-assign', 'DEV'),
  ('ai_router.threshold_weak_review_confidence', '0.30', 'ai-router: below this + low crossref -> demote to none', 'DEV'),
  ('ai_router.threshold_weak_review_crossref', '0.20', 'ai-router: crossref threshold for weak review demotion', 'DEV')
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  description = EXCLUDED.description,
  updated_by = EXCLUDED.updated_by,
  updated_at = NOW();
