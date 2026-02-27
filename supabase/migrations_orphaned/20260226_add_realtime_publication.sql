-- Formalize Realtime publication membership in git (idempotent).
-- Ensures iOS live-sync tables are tracked in migrations rather than dashboard-only drift.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_publication
    WHERE pubname = 'supabase_realtime'
  ) THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'claim_grades'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.claim_grades;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'interactions'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.interactions;
    END IF;
  ELSE
    RAISE NOTICE 'Publication supabase_realtime not found; skipping publication membership changes.';
  END IF;
END
$$;
