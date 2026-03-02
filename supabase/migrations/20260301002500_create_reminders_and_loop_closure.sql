-- Migration: Create Reminders Table and Close Open Loop Function
-- Date: 2026-03-01
-- Scope: Epics 3.1 & 3.4 (P0)

-- Task B (Partial): Add missing columns to journal_open_loops
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'journal_open_loops' AND column_name = 'closed_by') THEN
        ALTER TABLE public.journal_open_loops ADD COLUMN closed_by text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'journal_open_loops' AND column_name = 'closure_proof') THEN
        ALTER TABLE public.journal_open_loops ADD COLUMN closure_proof jsonb;
    END IF;
END $$;

-- Task A: Create Reminders Table
CREATE TABLE IF NOT EXISTS public.reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type text NOT NULL, -- 'open_loop' | 'striking_signal' | 'calendar_prep' | 'deadline_claim' | 'vendor_promise' | 'manual'
  source_id uuid, -- FK to source row (e.g. journal_open_loops.id)
  interaction_id uuid REFERENCES public.interactions(id),
  project_id uuid REFERENCES public.projects(id),
  contact_id uuid REFERENCES public.contacts(id),
  reminder_title text NOT NULL,
  reminder_body text,
  trigger_at timestamptz NOT NULL,
  trigger_rule jsonb, -- {type: 'deadline_check', deadline_at, check_after_hours} or {type: 'interval', hours_after_creation}
  source_evidence jsonb, -- {excerpt, char_start, char_end, source_table, source_id}
  suggested_action jsonb, -- {type: 'send_text', draft, to} or {type: 'check_status', what}
  priority text DEFAULT 'normal' CHECK (priority IN ('high','normal','low')),
  status text DEFAULT 'pending' CHECK (status IN ('pending','fired','done','snoozed','dismissed')),
  snooze_count int DEFAULT 0,
  snoozed_until timestamptz,
  created_at timestamptz DEFAULT now(),
  fired_at timestamptz,
  resolved_at timestamptz,
  resolved_by text -- 'human' | 'auto_close' | 'staleness'
);

-- Task A: Indexes
CREATE INDEX IF NOT EXISTS idx_reminders_status_trigger ON public.reminders(status, trigger_at);
CREATE INDEX IF NOT EXISTS idx_reminders_source ON public.reminders(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_reminders_project ON public.reminders(project_id);
CREATE INDEX IF NOT EXISTS idx_reminders_contact ON public.reminders(contact_id);

-- Task A: RLS
ALTER TABLE public.reminders ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE tablename = 'reminders' AND policyname = 'Service role full access on reminders'
    ) THEN
        CREATE POLICY "Service role full access on reminders"
          ON public.reminders FOR ALL
          TO service_role
          USING (true)
          WITH CHECK (true);
    END IF;
END $$;

-- Task B: close_open_loop Function
DROP FUNCTION IF EXISTS public.close_open_loop(uuid, jsonb, text);
CREATE OR REPLACE FUNCTION public.close_open_loop(
  p_loop_id uuid, 
  p_proof jsonb, 
  p_closed_by text DEFAULT 'human'
)
RETURNS void AS $$
BEGIN
  -- 1. Update journal_open_loops
  UPDATE public.journal_open_loops
  SET status = 'closed',
      closed_at = now(),
      closed_by = p_closed_by,
      closure_proof = p_proof
  WHERE id = p_loop_id AND status != 'closed';
  
  -- 2. Resolve any linked pending reminders
  UPDATE public.reminders
  SET status = 'done',
      resolved_at = now(),
      resolved_by = p_closed_by
  WHERE source_type = 'open_loop'
    AND source_id = p_loop_id
    AND status IN ('pending','fired','snoozed');
END;
$$ LANGUAGE plpgsql;

-- Comments
COMMENT ON TABLE public.reminders IS 'Active reminders driven by journal loop closure and perception events';
COMMENT ON FUNCTION public.close_open_loop IS 'Closes an open loop and resolves its associated reminders in a single atomic transaction';
