-- Enforce idempotent writeback across retries.
-- Semantics: at most one feedback row per (span_id, source).
-- This keeps scheduler retries from duplicating feedback spam.

create unique index if not exists attribution_validation_feedback_span_id_source_uniq
  on public.attribution_validation_feedback (span_id, source);
;
