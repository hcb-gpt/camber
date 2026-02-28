-- Regression detector view for ops signal
-- Per STRAT TURN:73 taskpack=data_next_ops

CREATE OR REPLACE VIEW v_regression_detector_24h AS
WITH hourly_stats AS (
  SELECT 
    date_trunc('hour', created_at) as hour,
    count(*) as runs,
    count(*) FILTER (WHERE status = 'FAIL') as fails,
    ROUND(100.0 * count(*) FILTER (WHERE status = 'FAIL') / NULLIF(count(*), 0), 1) as fail_pct,
    sum(review_gap) as total_gap,
    ROUND(avg(review_gap)::numeric, 2) as avg_gap,
    ROUND(avg(override_reseeds)::numeric, 2) as avg_reseeds
  FROM pipeline_scoreboard_snapshots
  WHERE created_at > now() - interval '24 hours'
  GROUP BY date_trunc('hour', created_at)
),
previous_hour AS (
  SELECT 
    hour,
    LAG(fail_pct) OVER (ORDER BY hour) as prev_fail_pct,
    LAG(avg_gap) OVER (ORDER BY hour) as prev_avg_gap,
    LAG(avg_reseeds) OVER (ORDER BY hour) as prev_avg_reseeds
  FROM hourly_stats
)
SELECT 
  h.hour,
  h.runs,
  h.fails,
  h.fail_pct,
  h.avg_gap,
  h.avg_reseeds,
  -- Regression flags
  CASE WHEN h.fail_pct > COALESCE(p.prev_fail_pct, 0) THEN true ELSE false END as fail_rate_increased,
  CASE WHEN h.avg_gap > COALESCE(p.prev_avg_gap, 0) THEN true ELSE false END as gap_increased,
  CASE WHEN h.avg_reseeds > COALESCE(p.prev_avg_reseeds, 0) + 1 THEN true ELSE false END as reseed_churn_high,
  -- Delta values
  h.fail_pct - COALESCE(p.prev_fail_pct, 0) as fail_delta,
  h.avg_gap - COALESCE(p.prev_avg_gap, 0) as gap_delta,
  h.avg_reseeds - COALESCE(p.prev_avg_reseeds, 0) as reseed_delta
FROM hourly_stats h
LEFT JOIN previous_hour p ON p.hour = h.hour
ORDER BY h.hour DESC;

COMMENT ON VIEW v_regression_detector_24h IS
  'Hourly regression detection: flags increases in fail rate, review gap, and reseed churn over last 24h';;
