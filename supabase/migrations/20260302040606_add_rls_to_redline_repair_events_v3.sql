-- Add RLS to redline_repair_events and enforce service-role only access

ALTER TABLE public.redline_repair_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redline_repair_events FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    -- Drop the bad policy if it exists (from the earlier attempt)
    DROP POLICY IF EXISTS service_role_only ON public.redline_repair_events;
    
    -- Recreate it properly targeting explicitly service_role
    IF NOT EXISTS (
        SELECT 1 FROM pg_policy WHERE polname = 'service_role_only' AND polrelid = 'public.redline_repair_events'::regclass
    ) THEN
        CREATE POLICY service_role_only ON public.redline_repair_events
            FOR ALL
            TO service_role
            USING (true)
            WITH CHECK (true);
    END IF;
END $$;