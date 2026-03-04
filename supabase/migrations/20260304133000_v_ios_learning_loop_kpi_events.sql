CREATE OR REPLACE VIEW public.v_ios_learning_loop_kpi_events AS
SELECT
  id,
  created_at,
  log_level,
  message AS event_name,
  metadata->>'surface' AS surface,
  (metadata->>'queue_depth')::int AS queue_depth,
  (metadata->>'elapsed_ms')::int AS elapsed_ms,
  metadata->>'queue_hash' AS queue_hash,
  metadata->>'source' AS source,
  metadata->>'card_hash' AS card_hash,
  (metadata->>'had_ai_suggestion')::boolean AS had_ai_suggestion,
  (metadata->>'evidence_count')::int AS evidence_count,
  metadata->>'undo_of' AS undo_of,
  (metadata->>'age_ms')::int AS age_ms,
  metadata->>'request_id' AS request_id,
  metadata->>'status_code' AS status_code,
  metadata->>'action' AS action,
  metadata->>'error_code' AS error_code,
  function_version
FROM public.diagnostic_logs
WHERE function_name = 'ios_telemetry';

-- Materialized daily dashboard formulas could be built on top of this view.
-- For now, the view parses out the JSONB fields directly for BI tooling.
