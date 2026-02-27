
-- Fix adapter_status: drop permissive, add proper
DROP POLICY IF EXISTS "Service role full access" ON public.adapter_status;
CREATE POLICY "Service role only" ON public.adapter_status
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix belief_assumptions
DROP POLICY IF EXISTS "Service role full access" ON public.belief_assumptions;
CREATE POLICY "Service role only" ON public.belief_assumptions
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix belief_claims
DROP POLICY IF EXISTS "Service role full access" ON public.belief_claims;
CREATE POLICY "Service role only" ON public.belief_claims
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix belief_conflicts
DROP POLICY IF EXISTS "Service role full access" ON public.belief_conflicts;
CREATE POLICY "Service role only" ON public.belief_conflicts
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix belief_open_loops
DROP POLICY IF EXISTS "Service role full access" ON public.belief_open_loops;
CREATE POLICY "Service role only" ON public.belief_open_loops
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix claim_pointers
DROP POLICY IF EXISTS "Service role full access" ON public.claim_pointers;
CREATE POLICY "Service role only" ON public.claim_pointers
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix conflict_claims
DROP POLICY IF EXISTS "Service role full access" ON public.conflict_claims;
CREATE POLICY "Service role only" ON public.conflict_claims
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fix loop_pointers
DROP POLICY IF EXISTS "Service role full access" ON public.loop_pointers;
CREATE POLICY "Service role only" ON public.loop_pointers
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');
;
