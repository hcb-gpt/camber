-- 20260131134100_add_override_log_reseed_audit.sql
-- Adds audit fields to override_log for reseed tracking

ALTER TABLE override_log
  ADD COLUMN IF NOT EXISTS mode text NULL,
  ADD COLUMN IF NOT EXISTS requested_by text NULL,
  ADD COLUMN IF NOT EXISTS span_count_before integer NULL,
  ADD COLUMN IF NOT EXISTS attrib_count_before integer NULL,
  ADD COLUMN IF NOT EXISTS span_count_after integer NULL,
  ADD COLUMN IF NOT EXISTS attrib_count_after integer NULL,
  ADD COLUMN IF NOT EXISTS reseed_status text NULL;
ALTER TABLE override_log
  ADD CONSTRAINT override_log_mode_check
  CHECK (mode IS NULL OR mode IN ('resegment_only', 'resegment_and_reroute'));
ALTER TABLE override_log
  ADD CONSTRAINT override_log_reseed_status_check
  CHECK (reseed_status IS NULL OR reseed_status IN ('success', 'blocked_human_lock', 'error'));
