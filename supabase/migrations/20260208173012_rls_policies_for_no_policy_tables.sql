
-- api_keys: sensitive credentials, service_role only
CREATE POLICY "Service role only" ON public.api_keys
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- geo_places: pipeline reference data, service_role only
CREATE POLICY "Service role only" ON public.geo_places
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- idempotency_keys: pipeline dedup, service_role only
CREATE POLICY "Service role only" ON public.idempotency_keys
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- pipedream_run_logs: pipeline execution logs, service_role only
CREATE POLICY "Service role only" ON public.pipedream_run_logs
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- project_geo: project geocoding data, service_role only
CREATE POLICY "Service role only" ON public.project_geo
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- span_place_mentions: pipeline output, service_role only
CREATE POLICY "Service role only" ON public.span_place_mentions
  FOR ALL USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');
;
