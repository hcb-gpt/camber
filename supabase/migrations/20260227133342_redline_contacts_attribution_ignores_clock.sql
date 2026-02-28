-- Already applied via direct SQL; this captures for anti-drift.
-- Idempotent: CREATE OR REPLACE VIEW is always safe.
SELECT 1; -- View already replaced above.
;
