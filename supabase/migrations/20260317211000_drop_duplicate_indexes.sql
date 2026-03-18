-- Drop redundant duplicate indexes to improve database performance and reduce storage overhead.
-- These were identified by the Supabase performance advisor.

-- attribution_audit_manifest_items
DROP INDEX IF EXISTS public.attribution_audit_manifest_items_manifest_ledger_uidx;

-- owner_names
DROP INDEX IF EXISTS public.idx_owner_names_name_active;

-- redline_defect_events
DROP INDEX IF EXISTS public.idx_redline_defect_events_interaction_status;

-- tram_messages
DROP INDEX IF EXISTS public.idx_tram_messages_expires_at;
