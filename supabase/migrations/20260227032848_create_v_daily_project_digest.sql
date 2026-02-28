CREATE OR REPLACE VIEW public.v_daily_project_digest AS
WITH active_projects AS (
  SELECT id, name FROM projects WHERE status = 'active'
),
interaction_project AS (
  SELECT DISTINCT ON (i.interaction_id)
    i.interaction_id, i.contact_id, i.event_at_utc, i.channel,
    COALESCE(i.project_id, jc.project_id) AS resolved_project_id
  FROM interactions i
  LEFT JOIN journal_claims jc
    ON jc.call_id = i.interaction_id AND jc.active = true AND jc.project_id IS NOT NULL
  WHERE i.event_at_utc::date >= CURRENT_DATE - 1
  ORDER BY i.interaction_id, jc.attribution_confidence DESC NULLS LAST
),
claim_buckets AS (
  SELECT jc.project_id,
    CASE
      WHEN jc.claim_type IN ('blocker','concern') THEN 'alerts'
      WHEN jc.claim_type IN ('commitment','deadline') THEN 'planned'
      WHEN jc.claim_type IN ('fact','update') THEN 'completed'
      ELSE 'other'
    END AS bucket,
    CASE
      WHEN jc.created_at::date = CURRENT_DATE THEN 'today'
      WHEN jc.created_at::date = CURRENT_DATE - 1 THEN 'yesterday'
    END AS day_label,
    COUNT(*) AS cnt
  FROM journal_claims jc
  WHERE jc.active = true AND jc.created_at::date >= CURRENT_DATE - 1 AND jc.project_id IS NOT NULL
  GROUP BY jc.project_id, bucket, day_label
),
claims_pivot AS (
  SELECT project_id,
    SUM(cnt) FILTER (WHERE day_label='today' AND bucket='alerts') AS today_alerts,
    SUM(cnt) FILTER (WHERE day_label='today' AND bucket='planned') AS today_planned,
    SUM(cnt) FILTER (WHERE day_label='today' AND bucket='completed') AS today_completed,
    SUM(cnt) FILTER (WHERE day_label='today' AND bucket='other') AS today_other,
    SUM(cnt) FILTER (WHERE day_label='yesterday' AND bucket='alerts') AS yest_alerts,
    SUM(cnt) FILTER (WHERE day_label='yesterday' AND bucket='planned') AS yest_planned,
    SUM(cnt) FILTER (WHERE day_label='yesterday' AND bucket='completed') AS yest_completed,
    SUM(cnt) FILTER (WHERE day_label='yesterday' AND bucket='other') AS yest_other
  FROM claim_buckets GROUP BY project_id
),
top_claim AS (
  SELECT DISTINCT ON (jc.project_id)
    jc.project_id, jc.claim_type AS top_claim_type, jc.claim_text AS top_claim_text,
    jc.attribution_confidence AS top_claim_confidence
  FROM journal_claims jc
  WHERE jc.active = true AND jc.claim_type IN ('blocker','deadline')
    AND jc.created_at::date >= CURRENT_DATE - 1 AND jc.project_id IS NOT NULL
  ORDER BY jc.project_id, CASE jc.claim_type WHEN 'blocker' THEN 0 ELSE 1 END,
    jc.attribution_confidence DESC NULLS LAST, jc.created_at DESC
)
SELECT ap.name AS project_name,
  COALESCE(cp.today_alerts,0) AS today_alerts, COALESCE(cp.today_planned,0) AS today_planned,
  COALESCE(cp.today_completed,0) AS today_completed, COALESCE(cp.today_other,0) AS today_other,
  COALESCE(cp.yest_alerts,0) AS yest_alerts, COALESCE(cp.yest_planned,0) AS yest_planned,
  COALESCE(cp.yest_completed,0) AS yest_completed, COALESCE(cp.yest_other,0) AS yest_other,
  tc.top_claim_type, LEFT(tc.top_claim_text, 120) AS top_claim_excerpt, tc.top_claim_confidence
FROM active_projects ap
LEFT JOIN claims_pivot cp ON cp.project_id = ap.id
LEFT JOIN top_claim tc ON tc.project_id = ap.id
ORDER BY COALESCE(cp.today_alerts,0)+COALESCE(cp.yest_alerts,0) DESC,
  COALESCE(cp.today_planned,0)+COALESCE(cp.yest_planned,0) DESC, ap.name;;
