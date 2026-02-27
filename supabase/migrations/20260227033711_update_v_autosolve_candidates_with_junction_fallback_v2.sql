
DROP VIEW IF EXISTS public.v_autosolve_candidates;

CREATE VIEW public.v_autosolve_candidates AS
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
    cpa.weight
  FROM correspondent_project_affinity cpa
  JOIN projects p ON p.id = cpa.project_id
  WHERE cpa.weight > 0 AND p.status = 'active'
),
affinity_ranked AS (
  SELECT *,
    row_number() OVER (PARTITION BY contact_id ORDER BY weight DESC) AS rn,
    count(*) OVER (PARTITION BY contact_id) AS active_project_count
  FROM contact_active_affinity
),
junction_fallback AS (
  SELECT 
    pc.contact_id,
    pc.project_id,
    p.name AS project_name,
    count(*) OVER (PARTITION BY pc.contact_id) AS junction_active_count,
    row_number() OVER (PARTITION BY pc.contact_id ORDER BY p.name) AS jrn
  FROM project_contacts pc
  JOIN projects p ON p.id = pc.project_id AND p.status = 'active'
  WHERE pc.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM contact_active_affinity caa 
      WHERE caa.contact_id = pc.contact_id
    )
)
SELECT
  oi.id AS interaction_uuid,
  oi.interaction_id,
  oi.contact_id,
  oi.contact_name,
  oi.event_at_utc,
  oi.channel,
  c.contact_type,
  COALESCE(ar.active_project_count, 0) AS active_project_count,
  COALESCE(ar.project_id, jf.project_id) AS top_project_id,
  COALESCE(ar.project_name, jf.project_name) AS top_project_name,
  COALESCE(ar.weight, 0)::numeric AS top_weight,
  CASE
    WHEN c.contact_type = 'client' AND (ar.active_project_count >= 1 OR jf.junction_active_count = 1) THEN 'CLIENT_BYPASS'
    WHEN ar.active_project_count = 1 THEN 'SINGLE_ACTIVE'
    WHEN ar.active_project_count > 1 THEN 'MULTI_ACTIVE'
    WHEN jf.junction_active_count = 1 THEN 'JUNCTION_SINGLE'
    WHEN jf.junction_active_count > 1 THEN 'JUNCTION_MULTI'
    ELSE 'NO_AFFINITY'
  END AS resolve_rule,
  CASE
    WHEN c.contact_type = 'client' AND (ar.active_project_count >= 1 OR jf.junction_active_count = 1) THEN 1.0
    WHEN ar.active_project_count = 1 AND ar.weight > 1.0 THEN 0.95
    WHEN ar.active_project_count = 1 THEN 0.85
    WHEN jf.junction_active_count = 1 THEN 0.80
    ELSE NULL
  END::numeric AS auto_confidence,
  CASE
    WHEN c.contact_type = 'client' AND (ar.active_project_count >= 1 OR jf.junction_active_count = 1) THEN true
    WHEN ar.active_project_count = 1 THEN true
    WHEN jf.junction_active_count = 1 THEN true
    ELSE false
  END AS is_auto_resolvable
FROM orphan_interactions oi
JOIN contacts c ON c.id = oi.contact_id
LEFT JOIN affinity_ranked ar ON ar.contact_id = oi.contact_id AND ar.rn = 1
LEFT JOIN junction_fallback jf ON jf.contact_id = oi.contact_id AND jf.jrn = 1
ORDER BY 
  CASE 
    WHEN c.contact_type = 'client' THEN 0 
    WHEN ar.active_project_count = 1 THEN 1
    WHEN jf.junction_active_count = 1 THEN 2
    ELSE 3
  END,
  oi.event_at_utc DESC;
;
