CREATE OR REPLACE VIEW public.v_project_intelligence_coverage AS
WITH active_projects AS (
  SELECT id, name FROM projects WHERE status = 'active'
),
claims_2wk AS (
  SELECT jc.project_id,
    COUNT(*) AS claims_14d,
    COUNT(*) FILTER (WHERE jc.created_at >= CURRENT_DATE - 7) AS claims_7d,
    COUNT(*) FILTER (WHERE jc.created_at >= CURRENT_DATE - 14 AND jc.created_at < CURRENT_DATE - 7) AS claims_prev_7d,
    ROUND(COUNT(*)::numeric / 2, 1) AS claims_per_week_avg
  FROM journal_claims jc
  WHERE jc.active = true AND jc.created_at >= CURRENT_DATE - 14 AND jc.project_id IS NOT NULL
  GROUP BY jc.project_id
),
alert_ratio AS (
  SELECT jc.project_id,
    COUNT(*) AS total_recent,
    COUNT(*) FILTER (WHERE jc.claim_type IN ('blocker','concern')) AS alert_recent,
    ROUND(COUNT(*) FILTER (WHERE jc.claim_type IN ('blocker','concern'))::numeric
      / NULLIF(COUNT(*),0) * 100, 1) AS alert_pct
  FROM journal_claims jc
  WHERE jc.active = true AND jc.created_at >= CURRENT_DATE - 14 AND jc.project_id IS NOT NULL
  GROUP BY jc.project_id
)
SELECT ap.name AS project_name,
  COALESCE(c2.claims_per_week_avg,0) AS claims_per_week_avg,
  COALESCE(c2.claims_7d,0) AS claims_last_7d,
  COALESCE(c2.claims_prev_7d,0) AS claims_prev_7d,
  CASE WHEN COALESCE(c2.claims_7d,0) < 3 THEN true ELSE false END AS going_dark,
  CASE WHEN COALESCE(ar.alert_pct,0) > 40 THEN true ELSE false END AS troubled,
  COALESCE(ar.alert_pct,0) AS alert_pct,
  CASE
    WHEN COALESCE(c2.claims_7d,0) > COALESCE(c2.claims_prev_7d,0) * 1.1 THEN 'increasing'
    WHEN COALESCE(c2.claims_7d,0) < COALESCE(c2.claims_prev_7d,0) * 0.9 THEN 'decreasing'
    ELSE 'stable'
  END AS claim_velocity_trend
FROM active_projects ap
LEFT JOIN claims_2wk c2 ON c2.project_id = ap.id
LEFT JOIN alert_ratio ar ON ar.project_id = ap.id
ORDER BY
  CASE WHEN COALESCE(c2.claims_7d,0) < 3 THEN 0 ELSE 1 END,
  CASE WHEN COALESCE(ar.alert_pct,0) > 40 THEN 0 ELSE 1 END,
  COALESCE(c2.claims_7d,0) DESC, ap.name;;
