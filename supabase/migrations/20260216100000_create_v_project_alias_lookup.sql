-- Create the v_project_alias_lookup view
-- This view is queried by context-assembly, process-call, and gmail-context-lookup
-- to resolve project aliases to project IDs.

CREATE OR REPLACE VIEW v_project_alias_lookup AS
SELECT DISTINCT project_id, alias
FROM (
  -- Source 1: project_aliases table (explicit aliases)
  SELECT
    pa.project_id,
    pa.alias
  FROM project_aliases pa
  JOIN projects p ON p.id = pa.project_id
  WHERE pa.active = true
    AND p.status IN ('active', 'warranty', 'estimating')
    AND p.project_kind = 'client'
    AND p.id NOT IN (
      SELECT pab.project_id
      FROM project_attribution_blocklist pab
      WHERE pab.active = true
    )

  UNION ALL

  -- Source 2: Legacy aliases from projects.aliases[] array
  SELECT
    p.id AS project_id,
    unnest(p.aliases) AS alias
  FROM projects p
  WHERE p.aliases IS NOT NULL
    AND p.status IN ('active', 'warranty', 'estimating')
    AND p.project_kind = 'client'
    AND p.id NOT IN (
      SELECT pab.project_id
      FROM project_attribution_blocklist pab
      WHERE pab.active = true
    )
) combined
WHERE alias IS NOT NULL AND alias <> '';
COMMENT ON VIEW v_project_alias_lookup IS
  'Unified project alias lookup combining project_aliases table and legacy projects.aliases[] array. '
  'Filters to active/warranty/estimating client projects not on the attribution blocklist. '
  'Queried by context-assembly, process-call, and gmail-context-lookup edge functions.';
