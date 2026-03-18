-- Drop overly permissive public policies on diagnostic_logs
-- The Edge Functions writing to this table use the service_role key, which bypasses RLS.
-- Public read/write access is unnecessary and exposes sensitive telemetry data.

DROP POLICY IF EXISTS "edge_functions_insert" ON public.diagnostic_logs;
DROP POLICY IF EXISTS "edge_functions_select" ON public.diagnostic_logs;

-- Ensure RLS is enabled
ALTER TABLE public.diagnostic_logs ENABLE ROW LEVEL SECURITY;
