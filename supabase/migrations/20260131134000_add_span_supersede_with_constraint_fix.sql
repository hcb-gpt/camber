-- 20260131134000_add_span_supersede_with_constraint_fix.sql
-- Non-destructive: adds supersede columns + fixes unique constraint for reseed

-- Step 1: Add supersede columns
ALTER TABLE conversation_spans
  ADD COLUMN IF NOT EXISTS segment_generation integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS is_superseded boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS superseded_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS superseded_by_action_id uuid NULL;
-- Step 2: Drop CONSTRAINT (not index) - PATCHED per STRAT
ALTER TABLE conversation_spans
  DROP CONSTRAINT IF EXISTS conversation_spans_interaction_id_span_index_key;
-- Step 3: Add partial UNIQUE on active spans only
CREATE UNIQUE INDEX IF NOT EXISTS conversation_spans_active_unique
  ON conversation_spans (interaction_id, span_index)
  WHERE is_superseded = false;
COMMENT ON COLUMN conversation_spans.segment_generation IS
  'Monotonic version counter per interaction_id. Higher = newer segmentation.';
COMMENT ON COLUMN conversation_spans.is_superseded IS
  'Tombstone flag. True = replaced by newer generation.';
