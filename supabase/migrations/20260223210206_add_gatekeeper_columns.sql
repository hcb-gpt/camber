ALTER TABLE public.span_attributions
  ADD COLUMN IF NOT EXISTS gatekeeper_reason text,
  ADD COLUMN IF NOT EXISTS gatekeeper_details jsonb;;
