-- Backfill Runs Summary Table
-- Logs aggregate stats for each scheduler-backfill invocation.
-- Epic 1.2: scheduler backfill

CREATE TABLE IF NOT EXISTS backfill_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id text NOT NULL UNIQUE,
  source_table text NOT NULL,          -- 'scheduler_items' or 'journal_open_loops'
  rows_processed integer NOT NULL DEFAULT 0,
  rows_resolved integer NOT NULL DEFAULT 0,
  rows_needs_review integer NOT NULL DEFAULT 0,
  rows_failed integer NOT NULL DEFAULT 0,
  rows_empty integer NOT NULL DEFAULT 0,
  confidence_breakdown jsonb,          -- {"HIGH": N, "MEDIUM": M, ...}
  duration_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_br_source ON backfill_runs (source_table);
CREATE INDEX idx_br_created ON backfill_runs (created_at DESC);

COMMENT ON TABLE backfill_runs IS 'Aggregate stats per backfill invocation (Epic 1.2)';
