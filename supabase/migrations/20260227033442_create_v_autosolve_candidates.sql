CREATE OR REPLACE VIEW public.v_autosolve_candidates AS
WITH orphan_interactions AS (
  SELECT i.id, i.interaction_id, i.contact_id, i.contact_name, i.event_at_utc, i.channel
  FROM interactions i
  WHERE i.contact_id IS NOT NULL AND i.project_id IS NULL
),
contact_active_affinity AS (
  SELECT 
    cpa.contact_id, 
    cpa.project_id, 
    p.name AS project_name, 
    cpa.weight,
    p.status,
    row_number() OVER (PARTITION BY cpa.contact_id ORDER BY cpa.weight DESC) AS rn
  FROM correspondent_project_affinity cpa
  JOIN projects p ON p.id = cpa.project_id
  WHERE cpa.weight > 0 AND p.status = 'active'
),
contact_bucket AS (
  SELECT 
    caa.contact_id,
    count(DISTINCT caa.project_id) AS active_project_count,
    max(caa.weight) AS top_weight,
    (SELECT inner_caa.project_id FROM contact_active_affinity inner_caa WHERE inner_caa.contact_id = caa.contact_id AND inner_caa.rn = 1) AS top_project_id,
    (SELECT inner_caa.project_name FROM contact_active_affinity inner_caa WHERE inner_caa.contact_id = caa.contact_id AND inner_caa.rn = 1) AS top_project_name
  FROM contact_active_affinity caa
  GROUP BY caa.contact_id
)
SELECT
  oi.id AS interaction_uuid,
  oi.interaction_id,
  oi.contact_id,
  oi.contact_name,
  oi.event_at_utc,
  oi.channel,
  c.contact_type,
  cb.active_project_count,
  cb.top_project_id,
  cb.top_project_name,
  cb.top_weight,
  CASE
    WHEN c.contact_type = 'client' AND cb.active_project_count >= 1 THEN 'CLIENT_BYPASS'
    WHEN cb.active_project_count = 1 THEN 'SINGLE_ACTIVE'
    WHEN cb.active_project_count > 1 THEN 'MULTI_ACTIVE'
    ELSE 'NO_AFFINITY'
  END AS resolve_rule,
  CASE
    WHEN c.contact_type = 'client' AND cb.active_project_count >= 1 THEN 1.0
    WHEN cb.active_project_count = 1 AND cb.top_weight > 1.0 THEN 0.95
    WHEN cb.active_project_count = 1 THEN 0.85
    ELSE NULL
  END AS auto_confidence,
  CASE
    WHEN c.contact_type = 'client' AND cb.active_project_count >= 1 THEN true
    WHEN cb.active_project_count = 1 THEN true
    ELSE false
  END AS is_auto_resolvable
FROM orphan_interactions oi
JOIN contacts c ON c.id = oi.contact_id
LEFT JOIN contact_bucket cb ON cb.contact_id = oi.contact_id
ORDER BY 
  CASE WHEN c.contact_type = 'client' THEN 0 ELSE 1 END,
  oi.event_at_utc DESC;;
