CREATE TABLE IF NOT EXISTS public.gmail_context_cache (
  cache_key TEXT PRIMARY KEY,
  email_fingerprint TEXT NOT NULL,
  email_context JSONB NOT NULL DEFAULT '[]'::jsonb,
  email_lookup_meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gmail_context_cache_expires_at_idx
  ON public.gmail_context_cache (expires_at);
COMMENT ON TABLE public.gmail_context_cache IS
  'Bounded Gmail context cache keyed by normalized vendor email fingerprint.';
