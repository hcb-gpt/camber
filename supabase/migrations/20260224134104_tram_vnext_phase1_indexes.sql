-- Phase 1: TRAM performance indexes for 10x volume
-- Thread: tram-vnext

-- 1a) in_reply_to lookup (partial — only non-null rows)
CREATE INDEX IF NOT EXISTS idx_tram_messages_in_reply_to
  ON tram_messages (in_reply_to)
  WHERE in_reply_to IS NOT NULL;

-- 1b) Replace single-column correlation_id with composite
DROP INDEX IF EXISTS idx_tram_messages_correlation;
CREATE INDEX idx_tram_messages_correlation_created
  ON tram_messages (correlation_id, created_at DESC)
  WHERE correlation_id IS NOT NULL;

-- 1c) Replace single-column thread with composite
DROP INDEX IF EXISTS idx_tram_messages_thread;
CREATE INDEX idx_tram_messages_thread_created
  ON tram_messages (thread, created_at DESC)
  WHERE thread IS NOT NULL;

-- 1d) Queue by kind (for tram_my_queue kind filtering)
CREATE INDEX IF NOT EXISTS idx_tram_messages_to_kind_created
  ON tram_messages ("to", kind, created_at DESC);

-- 1e) Expiry filter (partial — only rows with expiry)
CREATE INDEX IF NOT EXISTS idx_tram_messages_expires
  ON tram_messages (expires_at)
  WHERE expires_at IS NOT NULL;
;
