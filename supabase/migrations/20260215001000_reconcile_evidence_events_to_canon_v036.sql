-- ============================================================
-- evidence_events schema reconciliation to canon v0.3.6
-- Directive: dev_evidence_events_write_once_schema_reconcile
-- Applied: 2026-02-15
-- ============================================================

-- Step 0: Drop dependent view that references ee.occurred_at
DROP VIEW IF EXISTS v_project_claims_for_review;
-- Step 1: Rename drifted columns
ALTER TABLE evidence_events RENAME COLUMN occurred_at TO occurred_at_utc;
ALTER TABLE evidence_events RENAME COLUMN payload_hash TO integrity_hash;
-- Step 2: Add missing spec columns
ALTER TABLE evidence_events ADD COLUMN IF NOT EXISTS participants_json jsonb;
ALTER TABLE evidence_events ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
ALTER TABLE evidence_events ADD COLUMN IF NOT EXISTS source_run_id text;
-- Step 3: Backfill updated_at for existing rows (set to created_at)
UPDATE evidence_events SET updated_at = created_at WHERE updated_at IS NULL;
-- Step 4: Add updated_at auto-update trigger
CREATE OR REPLACE FUNCTION update_evidence_events_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_evidence_events_updated_at
  BEFORE UPDATE ON evidence_events
  FOR EACH ROW
  EXECUTE FUNCTION update_evidence_events_updated_at();
-- Step 5: Extend write-once trigger to integrity_hash (renamed from payload_hash)
CREATE OR REPLACE FUNCTION enforce_payload_ref_write_once()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  -- payload_ref: write-once
  IF OLD.payload_ref IS NOT NULL AND NEW.payload_ref IS DISTINCT FROM OLD.payload_ref THEN
    RAISE EXCEPTION 'G9 VIOLATION: payload_ref is write-once and cannot be mutated. evidence_event_id=%', OLD.evidence_event_id;
  END IF;
  -- integrity_hash: write-once (canon v0.3.6)
  IF OLD.integrity_hash IS NOT NULL AND NEW.integrity_hash IS DISTINCT FROM OLD.integrity_hash THEN
    RAISE EXCEPTION 'G9 VIOLATION: integrity_hash is write-once and cannot be mutated. evidence_event_id=%', OLD.evidence_event_id;
  END IF;
  RETURN NEW;
END;
$$;
-- Step 6: Recreate dependent view with renamed column
CREATE OR REPLACE VIEW v_project_claims_for_review AS
SELECT
  p.id AS project_id,
  p.name AS project_name,
  bc.id AS claim_id,
  bc.claim_type,
  bc.short_text,
  bc.epistemic_status,
  bc.warrant_level,
  bc.origin_kind,
  bc.confidence,
  bc.lifecycle,
  bc.event_at_utc,
  bc.created_at AS claim_created_at,
  bc.contact_id,
  cp.id AS pointer_id,
  cp.source_type AS pointer_source_type,
  cp.source_id AS pointer_source_id,
  cp.char_start,
  cp.char_end,
  left(cp.span_text, 500) AS span_text_preview,
  cp.span_hash,
  cp.ts_start,
  cp.ts_end,
  cp.evidence_event_id,
  ee.occurred_at_utc AS evidence_occurred_at,
  ee.transcript_variant,
  c.id AS correction_id,
  c.correction_type,
  c.error_type,
  c.status AS correction_status,
  c.correction_text,
  c.original_value,
  c.corrected_value,
  c.corrected_by,
  c.created_at AS correction_created_at,
  CASE WHEN c.id IS NOT NULL THEN true ELSE false END AS has_correction,
  CASE WHEN cp.id IS NULL THEN true ELSE false END AS missing_pointer,
  CASE WHEN bc.lifecycle = 'disputed'::lifecycle_enum THEN true ELSE false END AS is_disputed,
  CASE
    WHEN cp.char_start IS NULL OR cp.char_end IS NULL THEN 'no_offsets'
    WHEN (cp.char_end - cp.char_start) < 500 THEN 'precise'
    WHEN (cp.char_end - cp.char_start) < 2000 THEN 'wide'
    WHEN cp.char_start = 1 THEN 'blanket'
    ELSE 'broad'
  END AS pointer_quality,
  CASE
    WHEN cp.char_start IS NOT NULL AND cp.char_end IS NOT NULL THEN cp.char_end - cp.char_start
    ELSE NULL::integer
  END AS span_width_chars
FROM belief_claims bc
  JOIN projects p ON p.id = bc.project_id
  LEFT JOIN claim_pointers cp ON cp.claim_id = bc.id
  LEFT JOIN evidence_events ee ON ee.evidence_event_id = cp.evidence_event_id
  LEFT JOIN corrections c ON c.belief_claim_id = bc.id
WHERE bc.project_id IS NOT NULL
ORDER BY p.name, bc.event_at_utc DESC NULLS LAST, bc.created_at DESC;
-- Step 7: Update comments
COMMENT ON COLUMN evidence_events.occurred_at_utc IS 'When the evidence event occurred (canon v0.3.6: occurred_at_utc)';
COMMENT ON COLUMN evidence_events.integrity_hash IS 'WRITE-ONCE: Content hash for integrity verification (canon v0.3.6: integrity_hash). Cannot be mutated once set.';
COMMENT ON COLUMN evidence_events.participants_json IS 'Structured participant data (canon v0.3.6)';
COMMENT ON COLUMN evidence_events.updated_at IS 'Auto-updated on each row modification';
COMMENT ON COLUMN evidence_events.source_run_id IS 'ID of the pipeline run that created this evidence event (canon v0.3.6)';
COMMENT ON TRIGGER trg_payload_ref_write_once ON evidence_events IS 'G9 invariant: payload_ref and integrity_hash are write-once. Ensures evidence immutability per canon v0.3.6.';
COMMENT ON TRIGGER trg_evidence_events_updated_at ON evidence_events IS 'Auto-update updated_at timestamp on row modification.';
