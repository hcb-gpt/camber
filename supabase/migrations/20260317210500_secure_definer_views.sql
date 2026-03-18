-- Revoke public access to SECURITY DEFINER views
-- These views bypass RLS and were mistakenly accessible to anon and authenticated roles.
-- Access should be restricted to service_role or specific administrative roles.

DO $$
DECLARE
    r RECORD;
    v_views TEXT[] := ARRAY[
        'v_single_project_invariant_violations', 
        'v_attribution_recovery_candidates', 
        'v_beside_direct_read_parity_72h', 
        'v_hours_by_user', 
        'v_claim_pointers_missing_evidence', 
        'kpi_review_reasons_entropy', 
        'v_hours_report_placeholder', 
        'v_hours_by_job', 
        'v_project_intelligence_coverage', 
        'pipeline_heartbeat'
    ];
    v_view_name TEXT;
BEGIN
    FOREACH v_view_name IN ARRAY v_views
    LOOP
        EXECUTE 'REVOKE ALL ON TABLE public.' || quote_ident(v_view_name) || ' FROM anon, authenticated;';
    END LOOP;
END $$;
