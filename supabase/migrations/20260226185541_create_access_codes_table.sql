
CREATE TABLE public.access_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL,
  code_enc text NOT NULL,
  location_description text,
  project_id uuid REFERENCES public.projects(id),
  contact_id uuid REFERENCES public.contacts(id),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  notes text
);

COMMENT ON TABLE public.access_codes IS 'Encrypted access codes for gates, locks, trailers, sheds, etc.';
COMMENT ON COLUMN public.access_codes.code_enc IS 'PGP symmetric encrypted via camber_pii_key in Vault';

ALTER TABLE public.access_codes ENABLE ROW LEVEL SECURITY;
;
