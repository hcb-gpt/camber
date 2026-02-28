-- Migration: Fix override_log.interaction_id type mismatch
-- Purpose: Change interaction_id from uuid to text to match interactions table
-- Date: 2026-01-31
--
-- ROOT CAUSE: interactions.interaction_id is TEXT (e.g., 'cll_06DSMZ295NYJDC8RF6SHEBVDKR')
--             but override_log.interaction_id was UUID, causing silent insert failures
--             for reseed operations.

-- Step 1: Drop any foreign key constraint if it exists
-- (There shouldn't be one, but being safe)
ALTER TABLE override_log DROP CONSTRAINT IF EXISTS override_log_interaction_id_fkey;
-- Step 2: Change column type from uuid to text
-- Using USING clause to cast existing UUID values to text
ALTER TABLE override_log
  ALTER COLUMN interaction_id TYPE text
  USING interaction_id::text;
-- Step 3: Add comment documenting the column
COMMENT ON COLUMN override_log.interaction_id IS
  'Text interaction_id (matches interactions.interaction_id format, e.g., cll_06DSMZ295NYJDC8RF6SHEBVDKR)';
