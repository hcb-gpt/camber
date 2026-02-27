-- Migration drift detector for ops
-- Lists recent migrations that may need git commit

CREATE OR REPLACE VIEW v_recent_migrations AS
SELECT 
  version,
  name,
  CASE 
    WHEN version LIKE '20260131%' THEN 'sprint0'
    WHEN version LIKE '20260130%' THEN 'pre-sprint'
    ELSE 'baseline'
  END as phase,
  to_timestamp(version::bigint / 1000000) as approx_date
FROM supabase_migrations.schema_migrations
WHERE version >= '20260130000000'
ORDER BY version DESC;

COMMENT ON VIEW v_recent_migrations IS
  'Recent migrations for drift detection. Shows phase (sprint0/pre-sprint/baseline)';

-- Function to get migration summary for drift closure
CREATE OR REPLACE FUNCTION get_migration_summary()
RETURNS TABLE (
  phase text,
  migration_count bigint,
  earliest_version text,
  latest_version text
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    CASE 
      WHEN version LIKE '20260131%' THEN 'sprint0'
      WHEN version LIKE '20260130%' THEN 'pre-sprint'
      ELSE 'baseline'
    END as phase,
    count(*) as migration_count,
    min(version) as earliest_version,
    max(version) as latest_version
  FROM supabase_migrations.schema_migrations
  GROUP BY 1
  ORDER BY 3 DESC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_migration_summary() IS
  'Migration summary by phase for drift detection';;
