-- Migration: add_segment_metadata_column
-- Sprint 0: Add segment_metadata jsonb to conversation_spans
-- Stores LLM segmenter output: boundary_confidence, boundary_quote, boundary_reason
--
-- DATA-1 approval required before applying

ALTER TABLE conversation_spans
  ADD COLUMN IF NOT EXISTS segment_metadata JSONB DEFAULT '{}'::jsonb;
COMMENT ON COLUMN conversation_spans.segment_metadata IS
  'Stores segmenter output: boundary_confidence (0-1), boundary_quote (<=50 chars), boundary_reason';
-- Index for queries on segment metadata (optional, add if needed for analytics)
-- CREATE INDEX IF NOT EXISTS idx_conversation_spans_segment_metadata
--   ON conversation_spans USING gin(segment_metadata);;
