-- Add RLS to redline_repair_events and enforce service-role only access

ALTER TABLE public.redline_repair_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redline_repair_events FORCE ROW LEVEL SECURITY;

-- Note: We intentionally avoid 'DROP POLICY IF EXISTS' as Supabase migration best practices
-- generally discourage it in favor of idempotent wrapper blocks, but in this specific
-- rescue flow we will wrap it in a DO block to ensure idempotency.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policy WHERE polname = 'service_role_only' AND polrelid = 'public.redline_repair_events'::regclass
    ) THEN
        CREATE POLICY service_role_only ON public.redline_repair_events
            FOR ALL
            TO public
            USING (auth.role() = 'service_role')
            WITH CHECK (auth.role() = 'service_role');
    ELSE
        -- Ensure the existing policy applies to the service_role database role.
        ALTER POLICY service_role_only ON public.redline_repair_events TO public;
        ALTER POLICY service_role_only ON public.redline_repair_events
            USING (auth.role() = 'service_role')
            WITH CHECK (auth.role() = 'service_role');
    END IF;
END $$;
