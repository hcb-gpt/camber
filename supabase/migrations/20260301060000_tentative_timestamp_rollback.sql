-- Migration: Tentative Timestamp Rollback
-- Date: 2026-03-01
-- Objective: Null out start_at_utc and due_at_utc in scheduler_items where time_resolution_audit shows confidence='TENTATIVE'.
-- Preserve resolved value in audit table.

BEGIN;

UPDATE public.scheduler_items si
SET 
  start_at_utc = NULL,
  due_at_utc = NULL
FROM public.time_resolution_audit tra
WHERE tra.source_id = si.id 
  AND tra.source_table = 'scheduler_items'
  AND tra.confidence = 'TENTATIVE'
  AND (si.start_at_utc IS NOT NULL OR si.due_at_utc IS NOT NULL);

-- Mark as un-applied in the audit table to accurately reflect state
UPDATE public.time_resolution_audit
SET applied = false
WHERE confidence = 'TENTATIVE'
  AND applied = true;

COMMIT;
