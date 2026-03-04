-- Camber iOS Truth-Forcing Surface KPI Dashboard Queries

-- 1. Pick Time (P90 and Median) over the last 24 hours
-- Tracks the time from surface appear to a valid user pick/interaction
WITH pick_times AS (
    SELECT elapsed_ms, queue_id, source
    FROM public.camber_metrics_pick_time
    WHERE created_at > NOW() - INTERVAL '24 hours'
)
SELECT 
    COUNT(*) as sample_count,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY elapsed_ms) as pick_time_median_ms,
    percentile_cont(0.90) WITHIN GROUP (ORDER BY elapsed_ms) as pick_time_p90_ms
FROM pick_times;

-- 2. Undo Rate & Commit Rate
-- Tracks how often users mislabel and use the 'Undo' functionality relative to total writes
WITH writes AS (
    SELECT COUNT(*) as total_writes 
    FROM public.camber_metrics_write_actions 
    WHERE created_at > NOW() - INTERVAL '24 hours'
),
undos AS (
    SELECT 
        COUNT(*) as total_undos
    FROM public.camber_metrics_undo_events
    WHERE created_at > NOW() - INTERVAL '24 hours'
)
SELECT 
    w.total_writes,
    u.total_undos,
    CASE 
        WHEN w.total_writes > 0 THEN u.total_undos::FLOAT / w.total_writes::FLOAT 
        ELSE 0 
    END as undo_rate
FROM writes w, undos u;

-- 3. Auth Friction Block Rate
-- Tracks how often users hit 401/403 blocks when attempting to interact
WITH total_interactions AS (
    SELECT COUNT(*) as count 
    FROM public.camber_metrics_write_actions 
    WHERE created_at > NOW() - INTERVAL '24 hours'
),
auth_blocks AS (
    SELECT COUNT(*) as count 
    FROM public.camber_metrics_auth_friction 
    WHERE created_at > NOW() - INTERVAL '24 hours' 
      AND friction_type IN ('AUTH_LOCK_BLOCKED', 'AUTH_LOCK_RECOVERY_LOCKED')
)
SELECT 
    t.count as successful_interactions,
    a.count as auth_blocked_interactions,
    CASE 
        WHEN (t.count + a.count) > 0 THEN a.count::FLOAT / (t.count + a.count)::FLOAT 
        ELSE 0 
    END as auth_block_rate
FROM total_interactions t, auth_blocks a;
