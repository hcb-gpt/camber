-- Migration: Fix review_queue.interaction_id type mismatch
-- Purpose: Change interaction_id from uuid to text to match interactions table
-- Date: 2026-01-31
--
-- ROOT CAUSE: interactions.interaction_id is TEXT (e.g., 'cll_06DSX0CVZHZK72VCVW54EH9G3C')
--             but review_queue.interaction_id was UUID, causing silent insert failures
--             when ai-router tries to queue items for review.
--
-- SAFETY: This matches the fix applied to override_log in migration 20260131141500

-- Step 1: Drop dependent view
DROP VIEW IF EXISTS v_review_queue_spans;
-- Step 2: Drop any foreign key constraint if it exists
ALTER TABLE review_queue DROP CONSTRAINT IF EXISTS review_queue_interaction_id_fkey;
-- Step 3: Change column type from uuid to text
ALTER TABLE review_queue
  ALTER COLUMN interaction_id TYPE text
  USING interaction_id::text;
-- Step 4: Add comment documenting the column
COMMENT ON COLUMN review_queue.interaction_id IS
  'Text interaction_id (matches interactions.interaction_id format, e.g., cll_06DSX0CVZHZK72VCVW54EH9G3C)';
-- Step 5: Recreate the view with updated join logic
-- Note: interactions.interaction_id is TEXT, so we join on that instead of i.id (uuid)
CREATE OR REPLACE VIEW v_review_queue_spans AS
WITH latest_attr AS (
  SELECT DISTINCT ON (sa.span_id)
    sa.span_id,
    to_jsonb(sa.*) AS attr_json,
    sa.attributed_at
  FROM span_attributions sa
  ORDER BY sa.span_id, sa.attributed_at DESC NULLS LAST
)
SELECT
  rq.id AS review_queue_id,
  rq.status AS review_status,
  COALESCE(rq.reason_codes, rq.reasons) AS reason_codes,
  rq.created_at AS review_created_at,
  rq.updated_at AS review_updated_at,
  rq.resolved_at AS review_resolved_at,
  rq.span_id,
  rq.interaction_id,
  cs.id AS span_row_id,
  NULLIF(to_jsonb(cs.*) ->> 'start_ms', '')::bigint AS span_start_ms,
  NULLIF(to_jsonb(cs.*) ->> 'end_ms', '')::bigint AS span_end_ms,
  LEFT(COALESCE(
    to_jsonb(cs.*) ->> 'transcript_segment',
    to_jsonb(cs.*) ->> 'transcript_text',
    to_jsonb(cs.*) ->> 'text',
    rq.context_payload ->> 'transcript_snippet',
    ''
  ), 600) AS transcript_snippet,
  i.id AS interaction_row_id,
  COALESCE(to_jsonb(i.*) ->> 'channel', 'unknown') AS channel,
  COALESCE(
    to_jsonb(i.*) ->> 'event_at_utc',
    to_jsonb(i.*) ->> 'occurred_at_utc',
    to_jsonb(i.*) ->> 'created_at'
  ) AS interaction_time,
  la.attributed_at AS attribution_at_utc,
  la.attr_json AS attribution_json,
  la.attr_json ->> 'decision' AS decision,
  NULLIF(la.attr_json ->> 'confidence', '')::numeric AS confidence,
  la.attr_json ->> 'project_id' AS predicted_project_id,
  la.attr_json ->> 'applied_project_id' AS applied_project_id,
  la.attr_json ->> 'attribution_lock' AS attribution_lock,
  (la.attr_json ->> 'needs_review')::boolean AS needs_review
FROM review_queue rq
LEFT JOIN conversation_spans cs ON cs.id = rq.span_id
LEFT JOIN interactions i ON i.interaction_id = COALESCE(
  rq.interaction_id,
  cs.interaction_id
)
LEFT JOIN latest_attr la ON la.span_id = rq.span_id;
