
ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS dob date,
  ADD COLUMN IF NOT EXISTS ssn_enc text;

COMMENT ON COLUMN public.contacts.ssn_enc IS 'SSN stored as plaintext — migrate to pgcrypto or vault when ready';
COMMENT ON COLUMN public.contacts.dob IS 'Date of birth';
;
