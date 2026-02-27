-- Retention policy for pipeline_scoreboard_snapshots
-- Per STRAT TURN:73: keep 14-30 days, auto-prune

-- Function to prune old snapshots
CREATE OR REPLACE FUNCTION prune_scoreboard_snapshots(
  p_retention_days integer DEFAULT 14
)
RETURNS TABLE (
  deleted_count bigint,
  oldest_remaining timestamptz,
  newest timestamptz
) AS $$
DECLARE
  v_deleted bigint;
  v_oldest timestamptz;
  v_newest timestamptz;
BEGIN
  -- Delete old snapshots
  WITH deleted AS (
    DELETE FROM pipeline_scoreboard_snapshots
    WHERE created_at < now() - (p_retention_days || ' days')::interval
    RETURNING id
  )
  SELECT count(*) INTO v_deleted FROM deleted;
  
  -- Get remaining range
  SELECT min(created_at), max(created_at) 
  INTO v_oldest, v_newest
  FROM pipeline_scoreboard_snapshots;
  
  RETURN QUERY SELECT v_deleted, v_oldest, v_newest;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION prune_scoreboard_snapshots(integer) IS
  'Prune snapshots older than N days (default 14). Call via cron or scheduled job.';

-- Add index for efficient pruning
CREATE INDEX IF NOT EXISTS idx_scoreboard_snapshots_created 
  ON pipeline_scoreboard_snapshots (created_at);

-- Create a view showing retention stats
CREATE OR REPLACE VIEW v_scoreboard_retention_stats AS
SELECT 
  count(*) as total_snapshots,
  min(created_at) as oldest,
  max(created_at) as newest,
  count(*) FILTER (WHERE created_at < now() - interval '14 days') as over_14d,
  count(*) FILTER (WHERE created_at < now() - interval '30 days') as over_30d,
  pg_size_pretty(pg_total_relation_size('pipeline_scoreboard_snapshots')) as table_size
FROM pipeline_scoreboard_snapshots;

COMMENT ON VIEW v_scoreboard_retention_stats IS
  'Retention stats: shows snapshot counts by age and table size';;
