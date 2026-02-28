-- Drop the old score_interaction function with 2 args
DROP FUNCTION IF EXISTS score_interaction(text, boolean);

-- The new single-arg version remains;
