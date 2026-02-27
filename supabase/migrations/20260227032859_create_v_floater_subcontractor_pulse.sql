CREATE OR REPLACE VIEW public.v_floater_subcontractor_pulse AS
WITH floater_contacts AS (
  SELECT c.id AS contact_id, c.name AS contact_name, c.phone, c.trade, c.company,
    COUNT(DISTINCT COALESCE(i.project_id, jc.project_id)) AS project_count
  FROM contacts c
  JOIN interactions i ON i.contact_id = c.id
  LEFT JOIN journal_claims jc ON jc.call_id = i.interaction_id AND jc.active = true AND jc.project_id IS NOT NULL
  WHERE COALESCE(i.project_id, jc.project_id) IS NOT NULL AND c.is_internal = false
  GROUP BY c.id, c.name, c.phone, c.trade, c.company
  HAVING COUNT(DISTINCT COALESCE(i.project_id, jc.project_id)) >= 3
),
week_activity AS (
  SELECT i.contact_id,
    COUNT(DISTINCT i.interaction_id) AS interactions_this_week,
    COUNT(DISTINCT COALESCE(i.project_id, jc.project_id))
      FILTER (WHERE COALESCE(i.project_id, jc.project_id) IS NOT NULL) AS projects_this_week
  FROM interactions i
  LEFT JOIN journal_claims jc ON jc.call_id = i.interaction_id AND jc.active = true AND jc.project_id IS NOT NULL
  WHERE i.event_at_utc >= date_trunc('week', CURRENT_DATE) AND i.contact_id IS NOT NULL
  GROUP BY i.contact_id
)
SELECT fc.contact_name, fc.phone, fc.trade, fc.company,
  fc.project_count AS total_projects,
  COALESCE(wa.interactions_this_week,0) AS interactions_this_week,
  COALESCE(wa.projects_this_week,0) AS projects_active_this_week,
  CASE WHEN fc.project_count >= 3 AND COALESCE(wa.interactions_this_week,0) > 0
    THEN true ELSE false END AS stretched_flag
FROM floater_contacts fc
LEFT JOIN week_activity wa ON wa.contact_id = fc.contact_id
ORDER BY
  CASE WHEN fc.project_count >= 3 AND COALESCE(wa.interactions_this_week,0) > 0 THEN 0 ELSE 1 END,
  COALESCE(wa.interactions_this_week,0) DESC, fc.project_count DESC;;
