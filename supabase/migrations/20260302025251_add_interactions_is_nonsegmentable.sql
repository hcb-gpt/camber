-- Add is_nonsegmentable flag to prevent pipeline loops on empty transcripts
ALTER TABLE interactions ADD COLUMN is_nonsegmentable boolean DEFAULT false;

-- Create an index to support fast exclusion in queues
CREATE INDEX idx_interactions_segmentable ON interactions (is_nonsegmentable) WHERE is_nonsegmentable = false;

-- Backfill existing interactions
UPDATE interactions
SET is_nonsegmentable = true
WHERE transcript_chars = 0 OR transcript_chars IS NULL;
