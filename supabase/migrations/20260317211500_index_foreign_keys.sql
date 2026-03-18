-- Add missing indexes on foreign keys to improve join performance and prevent deadlocks on cascading deletes
-- Identified by Supabase performance advisor

-- access_codes
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_access_codes_contact_id ON public.access_codes USING btree (contact_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_access_codes_project_id ON public.access_codes USING btree (project_id);

-- architecture_anchors
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_architecture_anchors_capability ON public.architecture_anchors USING btree (graph_plane, artifact_sha, capability_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_architecture_anchors_node ON public.architecture_anchors USING btree (graph_plane, artifact_sha, node_id);

-- attribution_audit_ledger
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attribution_audit_ledger_assigned_project ON public.attribution_audit_ledger USING btree (assigned_project_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attribution_audit_ledger_expected_project ON public.attribution_audit_ledger USING btree (expected_project_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attribution_audit_ledger_predicted_project ON public.attribution_audit_ledger USING btree (predicted_project_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attribution_audit_ledger_resolution_expected_project ON public.attribution_audit_ledger USING btree (resolution_expected_project_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attribution_audit_ledger_span_id ON public.attribution_audit_ledger USING btree (span_id);
