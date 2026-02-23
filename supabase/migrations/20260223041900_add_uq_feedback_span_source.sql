-- Unique index for idempotent LLM proxy review writes
-- Allows one feedback row per (span_id, source) combination
-- Sources: operator-validation-ui, llm_proxy_review, llm_assist
CREATE UNIQUE INDEX IF NOT EXISTS uq_feedback_span_source
ON attribution_validation_feedback (span_id, source);
