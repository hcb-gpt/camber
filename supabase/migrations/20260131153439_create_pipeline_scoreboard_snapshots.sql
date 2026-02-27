-- Pipeline scoreboard snapshots for regression tracking
-- Per STRAT TURN:72 taskpack=data_ops_1

CREATE TABLE IF NOT EXISTS pipeline_scoreboard_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id text NOT NULL,
  gen_max integer,
  spans_total bigint,
  spans_active bigint,
  attributions bigint,
  review_items bigint,
  review_gap bigint,
  override_reseeds bigint,
  status text NOT NULL CHECK (status IN ('PASS', 'FAIL')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_scoreboard_snapshots_interaction 
  ON pipeline_scoreboard_snapshots (interaction_id, created_at DESC);

CREATE INDEX idx_scoreboard_snapshots_status 
  ON pipeline_scoreboard_snapshots (status, created_at DESC);

COMMENT ON TABLE pipeline_scoreboard_snapshots IS
  'Audit trail of pipeline proof runs. Enables regression detection across replays.';;
