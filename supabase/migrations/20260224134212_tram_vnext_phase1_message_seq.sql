-- Phase 1: Add contention-free message sequence as turn counter alternative
-- Sequences use non-transactional increment — no row lock contention
-- Thread: tram-vnext

-- Global message sequence (no per-role contention)
CREATE SEQUENCE IF NOT EXISTS tram_message_seq START WITH 1 INCREMENT BY 1;

-- Add message_seq column to tram_messages (auto-populated on insert)
ALTER TABLE tram_messages
  ADD COLUMN IF NOT EXISTS message_seq BIGINT DEFAULT nextval('tram_message_seq');

-- Index for ordering by seq (alternative to turn-based ordering)
CREATE INDEX IF NOT EXISTS idx_tram_messages_to_seq
  ON tram_messages ("to", message_seq DESC);

-- Backfill existing rows: set message_seq from created_at order
-- This preserves relative ordering for historical messages
WITH ordered AS (
  SELECT receipt, ROW_NUMBER() OVER (ORDER BY created_at) AS rn
  FROM tram_messages
  WHERE message_seq IS NULL OR message_seq = 0
)
UPDATE tram_messages tm
SET message_seq = ordered.rn
FROM ordered
WHERE tm.receipt = ordered.receipt;

-- Reset sequence to max + 1
SELECT setval('tram_message_seq', COALESCE((SELECT MAX(message_seq) FROM tram_messages), 0) + 1);
;
