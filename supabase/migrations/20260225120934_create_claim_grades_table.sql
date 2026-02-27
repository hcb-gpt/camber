-- Redline Step 1: claim_grades table for human grading of journal_claims
-- Separate table from journal_claims to isolate pipeline output from human input

-- 1. Create the table
CREATE TABLE claim_grades (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES journal_claims(id),
  grade text NOT NULL CHECK (grade IN ('confirm', 'reject', 'correct')),
  correction_text text,
  graded_by text NOT NULL,
  graded_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  UNIQUE(claim_id, graded_by)
);

-- 2. Indexes for Redline queries
CREATE INDEX idx_claim_grades_claim_id ON claim_grades(claim_id);
CREATE INDEX idx_claim_grades_grade ON claim_grades(grade);
CREATE INDEX idx_claim_grades_graded_at ON claim_grades(graded_at DESC);

-- 3. RLS: mirror journal_claims pattern (service_role full access)
ALTER TABLE claim_grades ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role full access on claim_grades"
  ON claim_grades
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role');

-- 4. Extend journal_claims confirmation CHECK to include 'rejected'
ALTER TABLE journal_claims
  DROP CONSTRAINT chk_journal_claims_confirmation_state;
ALTER TABLE journal_claims
  ADD CONSTRAINT chk_journal_claims_confirmation_state
  CHECK (claim_confirmation_state IN ('confirmed', 'unconfirmed', 'rejected'));

-- 5. Add comment for schema documentation
COMMENT ON TABLE claim_grades IS 'Human grading of journal_claims for Redline feedback loop. Separate from pipeline output.';
COMMENT ON COLUMN claim_grades.grade IS 'confirm = claim is accurate, reject = claim is wrong, correct = claim needs correction (see correction_text)';
COMMENT ON COLUMN claim_grades.correction_text IS 'Human-provided corrected text when grade = correct';
COMMENT ON COLUMN claim_grades.graded_by IS 'Grader identity: chad, agent name, or user identifier';;
