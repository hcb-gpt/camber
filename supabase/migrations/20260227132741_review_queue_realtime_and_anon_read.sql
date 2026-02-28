-- Enable Realtime subscriptions for review_queue and grant anon read access.
-- Already applied via direct SQL; this migration captures it for anti-drift.

-- Idempotent re-add (no-op if already present)
DO $$
BEGIN
  -- Check if review_queue is already in the publication
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND tablename = 'review_queue'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE review_queue;
  END IF;
END $$;

-- Idempotent policy creation
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy 
    WHERE polrelid = 'review_queue'::regclass AND polname = 'anon_read_review_queue'
  ) THEN
    CREATE POLICY anon_read_review_queue ON review_queue
      FOR SELECT TO anon USING (true);
  END IF;
END $$;;
