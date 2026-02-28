
CREATE TABLE owner_phones (
  phone TEXT PRIMARY KEY,
  label TEXT,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE owner_phones IS 'Exclusion list of owner/shared phone numbers to filter from contact-facing views like redline_contacts';
;
