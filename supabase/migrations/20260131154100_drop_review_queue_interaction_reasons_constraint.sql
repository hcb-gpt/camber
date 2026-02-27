-- Drop the problematic unique constraint on (interaction_id, reasons)
-- This constraint blocks inserts when a new span has the same reasons as an old superseded span
-- The span_id uniqueness constraint is sufficient for deduplication
DROP INDEX IF EXISTS review_queue_interaction_reasons_uidx;;
