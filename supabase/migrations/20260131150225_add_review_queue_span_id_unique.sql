
-- Add unique constraint for review_queue upsert idempotency
-- Each span should have at most one pending review item

ALTER TABLE review_queue
ADD CONSTRAINT review_queue_span_id_key
UNIQUE (span_id);

COMMENT ON CONSTRAINT review_queue_span_id_key ON review_queue IS 
  'One review item per span - ai-router upserts on this constraint';
;
