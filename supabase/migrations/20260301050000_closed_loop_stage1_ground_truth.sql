-- =============================================================
-- Closed-Loop Training Stage 1: Ground Truth Infrastructure
-- =============================================================
-- Creates the synthetic_ground_truth table for storing expected
-- outcomes of synthetic test interactions, and adds an is_synthetic
-- guard column to the interactions table to prevent synthetic data
-- from mutating production priors.
-- =============================================================

-- 1. Create synthetic_ground_truth table
CREATE TABLE synthetic_ground_truth (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id text NOT NULL,
  run_id uuid,
  expected_taxonomy_state text CHECK (expected_taxonomy_state IN ('SINGLE_PROJECT', 'NEEDS_SPLIT', 'UNKNOWN')),
  expected_project_ids text[],
  expected_contact_id uuid,
  expected_span_count int,
  difficulty text CHECK (difficulty IN ('easy','medium','hard','adversarial')),
  scenario_type text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_sgt_interaction ON synthetic_ground_truth(interaction_id);
CREATE INDEX idx_sgt_run ON synthetic_ground_truth(run_id);
CREATE INDEX idx_sgt_difficulty ON synthetic_ground_truth(difficulty);

-- 2. Add is_synthetic column to interactions table
ALTER TABLE interactions ADD COLUMN IF NOT EXISTS is_synthetic boolean DEFAULT false;
CREATE INDEX idx_interactions_synthetic ON interactions(is_synthetic) WHERE is_synthetic = true;
COMMENT ON COLUMN interactions.is_synthetic IS 'True for synthetic/test interactions. Guards prevent synthetic data from mutating production priors (affinity_ledger, contact_project_associations).';
