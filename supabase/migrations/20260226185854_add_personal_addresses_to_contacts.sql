
ALTER TABLE public.contacts ADD COLUMN IF NOT EXISTS personal_addresses jsonb;
COMMENT ON COLUMN public.contacts.personal_addresses IS 'Array of personal property addresses (not project sites)';
;
