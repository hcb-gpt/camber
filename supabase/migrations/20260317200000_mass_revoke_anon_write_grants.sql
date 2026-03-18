-- Mass revoke of overly permissive default write grants for anon and authenticated roles.
-- This leaves read (SELECT) access untouched if RLS allows it, but closes the global
-- DML vulnerability on all tables/views except those required by the iOS app.

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
          AND table_name NOT IN ('claim_grades', 'redline_settings')
          AND table_type IN ('BASE TABLE', 'VIEW')
    ) LOOP
        EXECUTE 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.' || quote_ident(r.table_name) || ' FROM anon, authenticated;';
    END LOOP;
END $$;
