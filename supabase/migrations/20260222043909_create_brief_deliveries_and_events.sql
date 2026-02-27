
-- Brief deliveries: one row per digest sent
CREATE TABLE public.brief_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brief_date date NOT NULL,
  recipient text NOT NULL DEFAULT 'zack',
  digest_json jsonb NOT NULL,
  brief_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  
  -- LOOP_CLOSURE proof fields (CEO requirement)
  delivered_to text,          -- who got it
  delivered_at timestamptz,   -- when link was sent
  read_proof timestamptz,     -- first page open
  read_ip text,               -- IP of reader (lightweight verification)
  read_user_agent text,       -- UA of reader
  action_proof timestamptz,   -- when "Reviewed" was tapped
  time_to_action interval GENERATED ALWAYS AS (action_proof - read_proof) STORED
);

CREATE INDEX idx_brief_deliveries_date ON public.brief_deliveries(brief_date DESC);
CREATE INDEX idx_brief_deliveries_recipient ON public.brief_deliveries(recipient);

-- Brief events: granular event log
CREATE TABLE public.brief_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brief_id uuid NOT NULL REFERENCES public.brief_deliveries(id),
  event_type text NOT NULL CHECK (event_type IN ('created', 'delivered', 'opened', 'reviewed', 'action_click')),
  metadata jsonb DEFAULT '{}',
  ip_address text,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_brief_events_brief_id ON public.brief_events(brief_id);
CREATE INDEX idx_brief_events_type ON public.brief_events(event_type);

-- RLS: service role only (edge functions access via service key)
ALTER TABLE public.brief_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brief_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_all_brief_deliveries" ON public.brief_deliveries
  FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all_brief_events" ON public.brief_events
  FOR ALL USING (auth.role() = 'service_role');
;
