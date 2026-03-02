-- Grant SELECT to anon for tables queried by redline-thread read routes

GRANT SELECT ON public.redline_contacts_unified TO anon;
GRANT SELECT ON public.redline_contacts_unified_matview TO anon;

GRANT SELECT ON public.calls_raw TO anon;
GRANT SELECT ON public.conversation_spans TO anon;
GRANT SELECT ON public.evidence_events TO anon;
GRANT SELECT ON public.review_queue TO anon;
GRANT SELECT ON public.redline_settings TO anon;

-- Just in case RLS is ever enabled on these, add permissive SELECT policies for anon
DO $$
BEGIN
    BEGIN
        CREATE POLICY anon_read_calls_raw ON public.calls_raw FOR SELECT TO anon USING (true);
    EXCEPTION WHEN duplicate_object THEN NULL; END;

    BEGIN
        CREATE POLICY anon_read_conversation_spans ON public.conversation_spans FOR SELECT TO anon USING (true);
    EXCEPTION WHEN duplicate_object THEN NULL; END;

    BEGIN
        CREATE POLICY anon_read_evidence_events ON public.evidence_events FOR SELECT TO anon USING (true);
    EXCEPTION WHEN duplicate_object THEN NULL; END;

    BEGIN
        CREATE POLICY anon_read_review_queue ON public.review_queue FOR SELECT TO anon USING (true);
    EXCEPTION WHEN duplicate_object THEN NULL; END;

    BEGIN
        CREATE POLICY anon_read_redline_settings ON public.redline_settings FOR SELECT TO anon USING (true);
    EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
