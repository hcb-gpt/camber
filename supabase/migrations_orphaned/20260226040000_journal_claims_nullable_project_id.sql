-- v2.9.0: Allow journal_claims.project_id to be NULL for skip-attribution mode.
-- In skip-attribution mode, claims are extracted from spans without project
-- attribution so that human grading in Redline can build a GT training set.
-- All 6,198 existing rows have project_id populated; this only affects new inserts.
-- FK to projects(id) is preserved — non-null values must still reference a valid project.
ALTER TABLE journal_claims ALTER COLUMN project_id DROP NOT NULL;
