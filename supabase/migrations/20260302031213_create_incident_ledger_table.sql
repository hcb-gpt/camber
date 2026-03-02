CREATE TABLE IF NOT EXISTS public.incident_ledger (
  incident_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  surface text NOT NULL,          -- e.g. 'redline_ios_contacts', 'review_queue'
  category text NOT NULL,          -- 'synthetics_leak', 'auth_failure', 'data_quality', 'security'
  sample_ids jsonb DEFAULT '[]',   -- array of affected row IDs
  description text NOT NULL,
  reported_by text NOT NULL,       -- session ID of reporter
  reported_at timestamptz NOT NULL DEFAULT now(),
  fix_sha text,                    -- git commit that fixes it
  fix_deployed_at timestamptz,
  verification_proof text,         -- screenshot URL or TRAM receipt
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'fixed', 'verified', 'wontfix')),
  closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_incident_ledger_status ON public.incident_ledger(status);
CREATE INDEX IF NOT EXISTS idx_incident_ledger_surface ON public.incident_ledger(surface);
CREATE INDEX IF NOT EXISTS idx_incident_ledger_category ON public.incident_ledger(category);

COMMENT ON TABLE public.incident_ledger IS 'Canonical incident tracking for CAMBER/Redline quality issues. CEO-mandated, VP-enforced.';

ALTER TABLE public.incident_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable read/write for service role on incident_ledger" ON public.incident_ledger FOR ALL TO service_role USING (true) WITH CHECK (true);
