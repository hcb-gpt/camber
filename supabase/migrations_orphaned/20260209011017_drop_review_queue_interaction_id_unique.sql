-- Drop legacy unique index on review_queue.interaction_id
-- Root cause: PR-4 added span_id column + span_id unique index for span-level
-- review items, but the old interaction_id unique index was never dropped.
-- This prevented multi-span interactions from having >1 review_queue row,
-- causing false FAIL_REVIEW_GAP in proof_pack.sql.
--
-- Span-level uniqueness: review_queue_span_id_uq (WHERE span_id IS NOT NULL)
-- Lookup index retained: idx_review_queue_interaction_id (non-unique)
--
-- Source: DEV-11 (receipt: dev11_proof_pack_investigation_report)
-- Finding: DEV-6 (receipt: proof_pack_review_gap_schema_mismatch)

DROP INDEX IF EXISTS idx_review_queue_interaction_id_unique;
