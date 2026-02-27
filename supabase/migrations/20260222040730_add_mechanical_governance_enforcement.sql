
-- =============================================================
-- MECHANICAL GOVERNANCE ENFORCEMENT
-- Five rules that failed as standing orders, now enforced in SQL
-- =============================================================

-- 1. Add governance columns
ALTER TABLE public.tram_messages 
  ADD COLUMN IF NOT EXISTS proof_compliant boolean DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS governance_flags jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS governance_hold boolean DEFAULT false;

-- 2. INDEX for fast governance queries
CREATE INDEX IF NOT EXISTS idx_tram_governance_hold 
  ON public.tram_messages (governance_hold) WHERE governance_hold = true;
CREATE INDEX IF NOT EXISTS idx_tram_proof_compliant 
  ON public.tram_messages (proof_compliant) WHERE proof_compliant = false;

-- =============================================================
-- TRIGGER 1: PROOF GATE (completions must have proof)
-- Replaces: "completions without proof fields are not complete"
-- =============================================================
CREATE OR REPLACE FUNCTION tram_enforce_proof_gate()
RETURNS TRIGGER AS $$
BEGIN
  -- Only applies to completions
  IF NEW.kind = 'completion' THEN
    -- Check for real proof (not N/A, not NONE, not empty)
    IF NEW.content IS NOT NULL AND (
      NEW.content ~* 'GIT_PROOF:\s*[a-f0-9]{7,40}' OR
      NEW.content ~* 'DEPLOY_PROOF:\s*[^\s]' OR
      NEW.content ~* 'GIT_PROOF:\s*N/A' OR
      NEW.content ~* 'DEPLOY_PROOF:\s*N/A'
    ) THEN
      -- Has proof fields (even N/A counts as acknowledged)
      IF NEW.content ~* 'GIT_PROOF:\s*[a-f0-9]{7,40}' OR
         NEW.content ~* 'DEPLOY_PROOF:\s*[^\s]' THEN
        NEW.proof_compliant := true;
      ELSE
        -- N/A is acceptable only if no repo paths are claimed
        IF NEW.content ~* 'ora/' OR NEW.content ~* 'docs/' OR NEW.content ~* 'src/' THEN
          NEW.proof_compliant := false;
          NEW.governance_flags := NEW.governance_flags || 
            jsonb_build_array(jsonb_build_object(
              'rule', 'PROOF_GATE',
              'violation', 'Claims repo artifacts but GIT_PROOF is N/A',
              'detected_at', now()::text
            ));
          NEW.governance_hold := true;
        ELSE
          NEW.proof_compliant := true;
        END IF;
      END IF;
    ELSE
      -- No proof fields at all
      NEW.proof_compliant := false;
      NEW.governance_flags := NEW.governance_flags || 
        jsonb_build_array(jsonb_build_object(
          'rule', 'PROOF_GATE',
          'violation', 'Completion missing proof fields entirely',
          'detected_at', now()::text
        ));
      NEW.governance_hold := true;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_proof_gate ON public.tram_messages;
CREATE TRIGGER trg_enforce_proof_gate
  BEFORE INSERT ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_enforce_proof_gate();

-- =============================================================
-- TRIGGER 2: MILESTONE ACCEPTANCE AUTHORITY
-- Replaces: "only VP closes milestone gates"
-- =============================================================
CREATE OR REPLACE FUNCTION tram_enforce_milestone_authority()
RETURNS TRIGGER AS $$
BEGIN
  -- Detect milestone acceptance messages
  IF NEW.subject ~* 'milestone.*accept' OR NEW.subject ~* 'milestone.*pass' OR NEW.subject ~* 'milestone.*closed' THEN
    -- Check if from VP session
    IF NEW.for_session IS NULL OR NEW.for_session NOT IN ('strat-vp') THEN
      -- Check content for origin_session
      IF NEW.content IS NOT NULL AND NEW.content !~* 'ORIGIN_SESSION:\s*strat-vp' THEN
        NEW.governance_flags := NEW.governance_flags || 
          jsonb_build_array(jsonb_build_object(
            'rule', 'MILESTONE_AUTHORITY',
            'violation', 'Milestone acceptance from non-VP session',
            'detected_at', now()::text
          ));
        NEW.governance_hold := true;
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_milestone_authority ON public.tram_messages;
CREATE TRIGGER trg_enforce_milestone_authority
  BEFORE INSERT ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_enforce_milestone_authority();

-- =============================================================
-- TRIGGER 3: FOR_SESSION ACK ENFORCEMENT
-- Replaces: "don't intercept CEO messages" standing order
-- =============================================================
CREATE OR REPLACE FUNCTION tram_enforce_for_session_ack()
RETURNS TRIGGER AS $$
BEGIN
  -- Only fires on ACK updates (acked changing from false/null to true)
  IF NEW.acked = true AND (OLD.acked IS NULL OR OLD.acked = false) THEN
    -- If message has for_session set, check ack_by matches
    IF OLD.for_session IS NOT NULL AND OLD.for_session != '' THEN
      -- Extract role from for_session (e.g., 'strat-vp' -> check ack_by is from that session context)
      -- For now: if for_session contains 'ceo', only CHAD or strat-ceo sessions can ACK
      IF OLD.for_session ~* 'ceo' THEN
        -- Block non-CEO ACKs on CEO messages
        NEW.acked := false;
        NEW.acked_at := NULL;
        NEW.ack_by := NULL;
        NEW.ack_type := NULL;
        NEW.governance_flags := COALESCE(OLD.governance_flags, '[]'::jsonb) || 
          jsonb_build_array(jsonb_build_object(
            'rule', 'FOR_SESSION_ACK',
            'violation', format('ACK blocked: for_session=%s but ack attempted by %s', OLD.for_session, NEW.ack_by),
            'blocked_ack_by', NEW.ack_by,
            'detected_at', now()::text
          ));
        RETURN NEW;
      END IF;
      
      -- For VP-targeted messages, only VP can ACK
      IF OLD.for_session = 'strat-vp' AND NEW.ack_by IS NOT NULL THEN
        -- Allow it but flag if not from VP context (soft enforcement for now)
        NULL; -- VP messages get through, but we track
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_for_session_ack ON public.tram_messages;
CREATE TRIGGER trg_enforce_for_session_ack
  BEFORE UPDATE ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_enforce_for_session_ack();

-- =============================================================
-- TRIGGER 4: AUTO-REDIRECT "REQUEST NEXT TASK" 
-- Replaces: "pull from backlog, don't request assignments"
-- =============================================================
CREATE OR REPLACE FUNCTION tram_flag_task_requests()
RETURNS TRIGGER AS $$
BEGIN
  -- Detect "request next task/assignment" patterns
  IF NEW.kind = 'request' AND (
    NEW.subject ~* 'next_assignment' OR 
    NEW.subject ~* 'next_task' OR
    NEW.subject ~* 'ready_for_next' OR
    NEW.subject ~* 'poll_no_unclaimed'
  ) THEN
    NEW.governance_flags := NEW.governance_flags || 
      jsonb_build_array(jsonb_build_object(
        'rule', 'AUTONOMY_VIOLATION',
        'violation', 'Agent requested assignment instead of pulling from backlog',
        'from_agent', NEW.from_agent,
        'detected_at', now()::text
      ));
    -- Don't hold — but flag for dashboard
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_flag_task_requests ON public.tram_messages;
CREATE TRIGGER trg_flag_task_requests
  BEFORE INSERT ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_flag_task_requests();

-- =============================================================
-- TRIGGER 5: ARCHITECTURE-FIRST COMPLIANCE
-- Replaces: "query camber_map before multi-module work"
-- =============================================================
CREATE OR REPLACE FUNCTION tram_enforce_architecture_first()
RETURNS TRIGGER AS $$
BEGIN
  -- Only applies to completions on multi-module work
  IF NEW.kind = 'completion' AND NEW.content IS NOT NULL THEN
    -- Detect multi-module work by checking for edge function, migration, or schema references
    IF NEW.content ~* 'edge:' OR NEW.content ~* 'migration' OR 
       NEW.content ~* 'CREATE TABLE' OR NEW.content ~* 'ALTER TABLE' OR
       NEW.content ~* 'deploy_edge_function' THEN
      -- Check for architecture map evidence
      IF NEW.content !~* 'ARCH_MAP_CHECKED' AND 
         NEW.content !~* 'camber_map' AND
         NEW.content !~* 'upstream' AND
         NEW.content !~* 'downstream' THEN
        NEW.governance_flags := NEW.governance_flags || 
          jsonb_build_array(jsonb_build_object(
            'rule', 'ARCHITECTURE_FIRST',
            'violation', 'Multi-module completion without architecture map evidence',
            'detected_at', now()::text
          ));
        -- Soft flag for now, will escalate to hold after baseline
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_architecture_first ON public.tram_messages;
CREATE TRIGGER trg_enforce_architecture_first
  BEFORE INSERT ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_enforce_architecture_first();

-- =============================================================
-- GOVERNANCE DASHBOARD VIEW
-- =============================================================
CREATE OR REPLACE VIEW public.v_governance_dashboard AS
SELECT 
  -- Proof compliance
  COUNT(*) FILTER (WHERE kind = 'completion' AND created_at > now() - interval '24 hours') as completions_24h,
  COUNT(*) FILTER (WHERE kind = 'completion' AND proof_compliant = true AND created_at > now() - interval '24 hours') as proof_compliant_24h,
  COUNT(*) FILTER (WHERE kind = 'completion' AND proof_compliant = false AND created_at > now() - interval '24 hours') as proof_noncompliant_24h,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE kind = 'completion' AND proof_compliant = true AND created_at > now() - interval '24 hours') / 
    NULLIF(COUNT(*) FILTER (WHERE kind = 'completion' AND created_at > now() - interval '24 hours'), 0)
  , 1) as proof_compliance_pct,
  
  -- Governance holds
  COUNT(*) FILTER (WHERE governance_hold = true AND created_at > now() - interval '24 hours') as held_messages_24h,
  
  -- Autonomy violations
  COUNT(*) FILTER (WHERE governance_flags::text ~* 'AUTONOMY_VIOLATION' AND created_at > now() - interval '24 hours') as autonomy_violations_24h,
  
  -- Milestone authority violations  
  COUNT(*) FILTER (WHERE governance_flags::text ~* 'MILESTONE_AUTHORITY' AND created_at > now() - interval '24 hours') as milestone_authority_violations_24h,
  
  -- Architecture-first violations
  COUNT(*) FILTER (WHERE governance_flags::text ~* 'ARCHITECTURE_FIRST' AND created_at > now() - interval '24 hours') as architecture_first_violations_24h,
  
  -- FOR_SESSION violations
  COUNT(*) FILTER (WHERE governance_flags::text ~* 'FOR_SESSION_ACK' AND created_at > now() - interval '24 hours') as for_session_violations_24h,
  
  -- Total messages for ratio
  COUNT(*) FILTER (WHERE created_at > now() - interval '24 hours') as total_messages_24h
  
FROM public.tram_messages;

-- =============================================================
-- HELD ITEMS VIEW (what's blocked)
-- =============================================================
CREATE OR REPLACE VIEW public.v_governance_held AS
SELECT 
  receipt,
  subject,
  kind,
  from_agent,
  for_session,
  governance_flags,
  created_at
FROM public.tram_messages
WHERE governance_hold = true
ORDER BY created_at DESC;

COMMENT ON COLUMN public.tram_messages.proof_compliant IS 'Mechanically checked: does this completion have valid proof fields?';
COMMENT ON COLUMN public.tram_messages.governance_flags IS 'Array of rule violations detected by triggers';
COMMENT ON COLUMN public.tram_messages.governance_hold IS 'If true, this message has a governance violation that blocks acceptance';
;
