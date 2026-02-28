
-- Migration 012: Convert tram_index from TABLE to VIEW on tram_messages
-- Rationale: tram_index TABLE only had 231 rows vs 16,930 in tram_messages (98.6% data gap)
-- The VIEW exposes ALL messages through the tram_index interface with derived columns

-- Step 1: Drop RLS policy on the table
DROP POLICY IF EXISTS service_role_only ON tram_index;

-- Step 2: Drop the table
DROP TABLE IF EXISTS tram_index;

-- Step 3: Create VIEW with derived columns matching original schema
CREATE OR REPLACE VIEW tram_index AS
SELECT
  row_number() OVER (ORDER BY created_at)::integer AS id,
  filename,
  "to",
  from_agent,
  subject,
  receipt,
  correlation_id,
  turn,
  created_at,
  expires_at,
  priority,
  kind,
  thread,
  attachments,
  completes_receipt,
  resolution,
  proof,
  "trigger",
  reopened,
  reopens_receipt,
  reopen_reason,
  -- Derived columns
  upper("to") AS to_base_role,
  upper(split_part(from_agent, '-', 1)) AS from_base_role,
  false AS is_legacy
FROM tram_messages;

-- Step 4: Add comment
COMMENT ON VIEW tram_index IS 'VIEW on tram_messages providing backward-compatible tram_index interface with derived base_role columns. Migrated from TABLE in migration 012.';
;
