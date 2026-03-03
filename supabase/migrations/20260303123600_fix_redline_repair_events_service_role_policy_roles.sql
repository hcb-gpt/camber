-- Repair redline_repair_events RLS policy role targeting.
-- VP decision: keep policy TO public, gate writes with auth.role() = 'service_role'.

ALTER TABLE public.redline_repair_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redline_repair_events FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_only ON public.redline_repair_events;

CREATE POLICY service_role_only
  ON public.redline_repair_events
  FOR ALL
  TO public
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');
