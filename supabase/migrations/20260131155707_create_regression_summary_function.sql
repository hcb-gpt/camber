-- Regression summary function for quick ops check
-- Returns single row with regression status

CREATE OR REPLACE FUNCTION get_regression_summary()
RETURNS TABLE (
  period text,
  total_runs bigint,
  total_fails bigint,
  fail_pct numeric,
  avg_gap numeric,
  avg_reseeds numeric,
  has_regressions boolean,
  regression_types text[]
) AS $$
BEGIN
  RETURN QUERY
  WITH stats AS (
    SELECT 
      count(*) as runs,
      count(*) FILTER (WHERE status = 'FAIL') as fails,
      ROUND(100.0 * count(*) FILTER (WHERE status = 'FAIL') / NULLIF(count(*), 0), 1) as fail_pct,
      ROUND(avg(review_gap)::numeric, 2) as avg_gap,
      ROUND(avg(override_reseeds)::numeric, 2) as avg_reseeds
    FROM pipeline_scoreboard_snapshots
    WHERE created_at > now() - interval '24 hours'
  ),
  prev_stats AS (
    SELECT 
      ROUND(100.0 * count(*) FILTER (WHERE status = 'FAIL') / NULLIF(count(*), 0), 1) as fail_pct,
      ROUND(avg(review_gap)::numeric, 2) as avg_gap,
      ROUND(avg(override_reseeds)::numeric, 2) as avg_reseeds
    FROM pipeline_scoreboard_snapshots
    WHERE created_at BETWEEN now() - interval '48 hours' AND now() - interval '24 hours'
  ),
  regressions AS (
    SELECT array_remove(ARRAY[
      CASE WHEN s.fail_pct > COALESCE(p.fail_pct, 0) + 5 THEN 'fail_rate' END,
      CASE WHEN s.avg_gap > COALESCE(p.avg_gap, 0) THEN 'review_gap' END,
      CASE WHEN s.avg_reseeds > COALESCE(p.avg_reseeds, 0) + 2 THEN 'reseed_churn' END
    ], NULL) as types
    FROM stats s, prev_stats p
  )
  SELECT 
    'last_24h'::text,
    s.runs::bigint,
    s.fails::bigint,
    s.fail_pct,
    s.avg_gap,
    s.avg_reseeds,
    cardinality(r.types) > 0,
    r.types
  FROM stats s, regressions r;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_regression_summary() IS
  'Quick ops check: returns 24h summary with regression flags';;
