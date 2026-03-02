-- Redline Truth Graph repair events
-- Durable audit trail for idempotent repair hooks invoked via edge:redline-thread.

CREATE TABLE IF NOT EXISTS public.redline_repair_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id text NOT NULL,
  repair_action text NOT NULL,
  idempotency_key text NOT NULL,
  requested_by text,
  status text NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'succeeded', 'failed')),
  error_code text,
  detail jsonb,
  started_at_utc timestamptz NOT NULL DEFAULT now(),
  completed_at_utc timestamptz,
  function_version text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS redline_repair_events_idempotency_key_uq
  ON public.redline_repair_events (idempotency_key);

CREATE INDEX IF NOT EXISTS redline_repair_events_interaction_id_idx
  ON public.redline_repair_events (interaction_id);

CREATE INDEX IF NOT EXISTS redline_repair_events_started_at_idx
  ON public.redline_repair_events (started_at_utc);

COMMENT ON TABLE public.redline_repair_events IS
'Durable audit log for idempotent repair hooks (truth-forcing).';

COMMENT ON COLUMN public.redline_repair_events.idempotency_key IS
'Client-provided idempotency key; unique to prevent double-apply writes.';

