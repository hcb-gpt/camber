
-- Add unique constraint for ai-router upsert idempotency
-- This allows the same span to be re-routed by the same model/prompt, updating the attribution
-- The existing (span_id, project_id) constraint prevents duplicate attributions to the same project

ALTER TABLE span_attributions
ADD CONSTRAINT span_attributions_span_model_prompt_key
UNIQUE (span_id, model_id, prompt_version);

COMMENT ON CONSTRAINT span_attributions_span_model_prompt_key ON span_attributions IS 
  'Idempotency constraint for ai-router: allows upsert when re-routing same span with same model/prompt';
;
