-- Migration: Routine to funnel diagnostic_logs telemetry into KPI metrics schema

CREATE OR REPLACE FUNCTION public.process_triage_telemetry()
RETURNS trigger AS $$
BEGIN
    IF NEW.message != 'triage_surface_interaction' THEN
        RETURN NEW;
    END IF;

    IF NEW.metadata->>'event_type' = 'pick_time_sample' THEN
        INSERT INTO public.camber_metrics_pick_time (created_at, queue_id, elapsed_ms, surface, source, had_ai_suggestion, evidence_count, session_id)
        VALUES (
            NEW.created_at,
            NEW.metadata->'payload'->>'queue_id',
            (NEW.metadata->'payload'->>'elapsed_ms')::integer,
            NEW.metadata->>'surface',
            NEW.metadata->'payload'->>'source',
            (NEW.metadata->'payload'->>'had_ai_suggestion')::integer = 1,
            (NEW.metadata->'payload'->>'evidence_count')::integer,
            NULL
        );
    ELSIF NEW.metadata->>'event_type' = 'write_action' THEN
        INSERT INTO public.camber_metrics_write_actions (created_at, queue_id, request_id, action_type, surface, session_id)
        VALUES (
            NEW.created_at,
            NEW.metadata->'payload'->>'queue_id',
            NEW.metadata->'payload'->>'request_id',
            NEW.metadata->'payload'->>'action',
            NEW.metadata->>'surface',
            NULL
        );
    ELSIF NEW.metadata->>'event_type' = 'undo_commit' THEN
        INSERT INTO public.camber_metrics_undo_events (created_at, queue_id, undo_of, age_ms, surface, session_id)
        VALUES (
            NEW.created_at,
            NEW.metadata->'payload'->>'queue_id',
            NEW.metadata->'payload'->>'undo_of',
            0, -- Defaulting age_ms as it's not present in this payload
            NEW.metadata->>'surface',
            NULL
        );
    ELSIF NEW.metadata->>'event_type' = 'AUTH_LOCK_UI_DISABLED' OR NEW.metadata->>'event_type' = 'AUTH_LOCK_RECOVERY_LOCKED' OR NEW.metadata->>'event_type' = 'AUTH_LOCK_BLOCKED' THEN
        INSERT INTO public.camber_metrics_auth_friction (created_at, status_code, friction_type, action_type, surface, queue_id, session_id)
        VALUES (
            NEW.created_at,
            (NEW.metadata->'payload'->>'status_code')::integer,
            NEW.metadata->>'event_type',
            NEW.metadata->'payload'->>'action',
            NEW.metadata->>'surface',
            NEW.metadata->'payload'->>'queue_id',
            NULL
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop trigger if it exists
DROP TRIGGER IF EXISTS triage_telemetry_insert_trigger ON public.diagnostic_logs;

-- Create the trigger
CREATE TRIGGER triage_telemetry_insert_trigger
AFTER INSERT ON public.diagnostic_logs
FOR EACH ROW
EXECUTE FUNCTION public.process_triage_telemetry();
