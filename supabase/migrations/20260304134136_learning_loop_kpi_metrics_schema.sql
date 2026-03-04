-- Migration: Create Camber iOS Learning Loop KPI Metrics Tables

-- 1. camber_metrics_pick_time
CREATE TABLE IF NOT EXISTS public.camber_metrics_pick_time (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    queue_id TEXT NOT NULL,
    elapsed_ms INTEGER NOT NULL,
    surface TEXT NOT NULL,
    source TEXT NOT NULL,
    had_ai_suggestion BOOLEAN DEFAULT FALSE,
    evidence_count INTEGER DEFAULT 0,
    session_id TEXT
);

-- 2. camber_metrics_write_actions
CREATE TABLE IF NOT EXISTS public.camber_metrics_write_actions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    queue_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    action_type TEXT NOT NULL, -- e.g., 'resolve_single', 'dismiss_bulk'
    surface TEXT NOT NULL,
    session_id TEXT
);

-- 3. camber_metrics_undo_events
CREATE TABLE IF NOT EXISTS public.camber_metrics_undo_events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    queue_id TEXT NOT NULL,
    undo_of TEXT NOT NULL,
    age_ms INTEGER NOT NULL,
    surface TEXT NOT NULL,
    session_id TEXT
);

-- 4. camber_metrics_auth_friction
CREATE TABLE IF NOT EXISTS public.camber_metrics_auth_friction (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    status_code INTEGER NOT NULL,
    friction_type TEXT NOT NULL, -- e.g., 'AUTH_LOCK_BLOCKED', 'AUTH_LOCK_UI_DISABLED'
    action_type TEXT,
    surface TEXT NOT NULL,
    queue_id TEXT,
    session_id TEXT
);

-- Add basic service_role write access
GRANT ALL ON public.camber_metrics_pick_time TO service_role;
GRANT ALL ON public.camber_metrics_write_actions TO service_role;
GRANT ALL ON public.camber_metrics_undo_events TO service_role;
GRANT ALL ON public.camber_metrics_auth_friction TO service_role;
