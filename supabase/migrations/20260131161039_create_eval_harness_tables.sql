-- eval_harness tables: eval_runs + eval_samples
-- Phase 2 eval harness skeleton from GPT-DEV-5

-- 1) eval_runs: one row per evaluation run
CREATE TABLE IF NOT EXISTS eval_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,                      -- actor id/email
  name text NOT NULL,
  description text NULL,

  -- target population definition (frozen for reproducibility)
  population_query text NOT NULL,                -- SQL text or named query key
  population_params jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- sampling config (frozen)
  sampling_strategy text NOT NULL,               -- 'uniform'|'risk_weighted'|'stratified'
  sampling_params jsonb NOT NULL DEFAULT '{}'::jsonb, -- e.g. N, strata, risk weights, seed

  -- execution config (frozen)
  replay_flags jsonb NOT NULL DEFAULT '{}'::jsonb,    -- {"reseed":true,"reroute":true}
  proof_required boolean NOT NULL DEFAULT true,

  -- status lifecycle
  status text NOT NULL DEFAULT 'created',        -- created|queued|running|complete|failed|canceled
  started_at timestamptz NULL,
  completed_at timestamptz NULL,

  -- summary metrics (denormalized for dashboard)
  total_samples int NOT NULL DEFAULT 0,
  pass_count int NOT NULL DEFAULT 0,
  fail_count int NOT NULL DEFAULT 0,

  -- receipts / audit
  client_request_id text NULL UNIQUE             -- idempotency key for run creation
);

CREATE INDEX IF NOT EXISTS eval_runs_status_idx ON eval_runs(status);
CREATE INDEX IF NOT EXISTS eval_runs_created_at_idx ON eval_runs(created_at DESC);

-- 2) eval_samples: one row per sampled target (interaction or span)
CREATE TABLE IF NOT EXISTS eval_samples (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),

  eval_run_id uuid NOT NULL REFERENCES eval_runs(id) ON DELETE CASCADE,

  -- target
  interaction_id text NOT NULL,
  generation int NULL,                           -- optional pin; null means "latest at execution time"
  span_id uuid NULL,                             -- optional if doing span-level eval

  -- frozen sampling metadata
  sample_rank int NOT NULL,                      -- stable ordering in run
  sampling_weight numeric NULL,
  sampling_reason text NULL,                     -- e.g. "high_risk_missing_receipts"

  -- execution state
  status text NOT NULL DEFAULT 'queued',         -- queued|running|pass|fail|skipped
  started_at timestamptz NULL,
  completed_at timestamptz NULL,

  -- proof artifacts
  proof_dir text NULL,                           -- e.g. /tmp/proofs/<interaction_id>/<ts>/
  proof_index_json text NULL,                    -- pointer to manifest file if exists
  scoreboard_json jsonb NULL,                    -- minimal scoreboard snapshot
  first_fail_rows_json jsonb NULL,               -- first failing rows summary if FAIL

  -- receipts / audit
  client_request_id text NULL UNIQUE             -- idempotency key for sample enqueue
);

CREATE INDEX IF NOT EXISTS eval_samples_run_rank ON eval_samples(eval_run_id, sample_rank);
CREATE INDEX IF NOT EXISTS eval_samples_interaction ON eval_samples(interaction_id);
CREATE INDEX IF NOT EXISTS eval_samples_status ON eval_samples(status);

-- 3) eval_events: append-only log for state transitions (optional but useful)
CREATE TABLE IF NOT EXISTS eval_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  eval_run_id uuid NOT NULL REFERENCES eval_runs(id) ON DELETE CASCADE,
  eval_sample_id uuid NULL REFERENCES eval_samples(id) ON DELETE CASCADE,
  actor text NOT NULL,
  event_type text NOT NULL,                      -- run_created|sample_queued|sample_pass|sample_fail|...
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS eval_events_run_idx ON eval_events(eval_run_id);
CREATE INDEX IF NOT EXISTS eval_events_sample_idx ON eval_events(eval_sample_id);

COMMENT ON TABLE eval_runs IS 'Evaluation runs with frozen population/sampling/replay configs';
COMMENT ON TABLE eval_samples IS 'Individual samples in an eval run with proof artifact pointers';
COMMENT ON TABLE eval_events IS 'Append-only event log for eval state transitions';;
