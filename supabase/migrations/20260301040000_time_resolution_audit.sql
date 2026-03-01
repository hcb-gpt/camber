-- Time Resolution Audit Table
-- Tracks backfill runs of the time_resolver against scheduler_items and journal_open_loops.
-- Epic 1.2: scheduler backfill

CREATE TABLE IF NOT EXISTS time_resolution_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_table text NOT NULL,        -- 'scheduler_items' or 'journal_open_loops'
  source_id uuid NOT NULL,           -- FK to source row
  time_hint text NOT NULL,           -- input text sent to resolver
  anchor_ts timestamptz NOT NULL,    -- anchor timestamp used for resolution
  start_at_utc timestamptz,          -- resolved start
  end_at_utc timestamptz,            -- resolved end (from resolver, may not map to source column)
  due_at_utc timestamptz,            -- resolved due
  confidence text NOT NULL,          -- HIGH, MEDIUM, TENTATIVE, LOW
  needs_review boolean NOT NULL DEFAULT false,
  reason_code text,
  evidence_quote text,
  timezone text,
  applied boolean NOT NULL DEFAULT false,  -- true if we wrote back to source table
  backfill_run_id text NOT NULL,     -- groups rows from same invocation
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tra_source ON time_resolution_audit (source_table, source_id);
CREATE INDEX idx_tra_run ON time_resolution_audit (backfill_run_id);
CREATE INDEX idx_tra_confidence ON time_resolution_audit (confidence) WHERE NOT applied;

COMMENT ON TABLE time_resolution_audit IS 'Audit trail for time_resolver backfill runs (Epic 1.2)';
