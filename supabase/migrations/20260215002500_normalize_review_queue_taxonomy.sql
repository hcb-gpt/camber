-- Normalize review_queue resolution taxonomy.
-- Fixes: status/action mismatches, variant canonicalization, CHECK constraint guardrail.
--
-- Before: 25 unique (status, resolution_action, resolved_by) combinations with
-- inconsistent casing (BULK_APPROVE, APPROVE), variant naming (auto_dismissed vs
-- auto_dismiss, auto_resolved vs auto_resolved_backfill), status/action contradictions
-- (resolved+dismissed, resolved+unresolved, pending+auto_resolved).
--
-- After: 3 statuses (pending, resolved, dismissed), 8 canonical actions, CHECK constraints.

-- 1. Fix status/action mismatches
UPDATE review_queue SET status = 'resolved', resolved_at = COALESCE(resolved_at, now())
WHERE status = 'pending' AND resolution_action = 'auto_resolved';
UPDATE review_queue SET status = 'dismissed', resolved_at = COALESCE(resolved_at, now())
WHERE status = 'pending' AND resolution_action = 'auto_dismiss';
UPDATE review_queue SET status = 'dismissed', resolved_at = COALESCE(resolved_at, now())
WHERE status = 'pending' AND resolution_action = 'duplicate_dismissed';
-- 2. Canonicalize auto_dismiss variants
UPDATE review_queue SET resolution_action = 'auto_dismiss' WHERE resolution_action = 'auto_dismissed';
-- 3. Case normalization for manual actions
UPDATE review_queue SET resolution_action = 'manual_approve' WHERE resolution_action IN ('BULK_APPROVE', 'APPROVE');
UPDATE review_queue SET resolution_action = 'manual_reject' WHERE resolution_action = 'REJECT';
UPDATE review_queue SET resolution_action = 'manual_attribute' WHERE resolution_action = 'attributed';
-- 4. Fix contradictory action values
UPDATE review_queue SET status = 'dismissed', resolution_action = 'auto_dismiss'
WHERE status = 'resolved' AND resolution_action = 'dismissed';
UPDATE review_queue
SET status = 'dismissed', resolution_action = 'auto_dismiss',
    resolution_notes = COALESCE(resolution_notes, '') || ' [normalized from resolved+unresolved]'
WHERE status = 'resolved' AND resolution_action = 'unresolved';
UPDATE review_queue SET resolution_action = 'auto_resolve' WHERE resolution_action = 'auto_resolved_backfill';
UPDATE review_queue SET resolution_action = 'auto_resolve' WHERE resolution_action = 'auto_resolved';
UPDATE review_queue SET resolution_action = 'auto_promote' WHERE resolution_action = 'auto_promoted';
-- 5. Fill nulls on resolved/dismissed rows
UPDATE review_queue
SET resolution_action = 'auto_dismiss', resolved_by = COALESCE(resolved_by, 'system:taxonomy_normalization')
WHERE status = 'dismissed' AND resolution_action IS NULL;
UPDATE review_queue
SET resolution_action = 'confirmed', resolved_by = COALESCE(resolved_by, 'system:taxonomy_normalization')
WHERE status = 'resolved' AND resolution_action IS NULL;
-- 6. CHECK constraints as guardrails
ALTER TABLE review_queue
  ADD CONSTRAINT review_queue_status_check
  CHECK (status IN ('pending', 'resolved', 'dismissed'));
ALTER TABLE review_queue
  ADD CONSTRAINT review_queue_resolution_action_check
  CHECK (resolution_action IS NULL OR resolution_action IN (
    'auto_dismiss', 'auto_resolve', 'auto_promote',
    'manual_approve', 'manual_reject', 'manual_attribute',
    'confirmed', 'duplicate_dismissed'
  ));
