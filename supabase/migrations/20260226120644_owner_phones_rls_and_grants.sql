
-- Enable RLS
ALTER TABLE owner_phones ENABLE ROW LEVEL SECURITY;

-- SELECT policy for anon and authenticated
CREATE POLICY "owner_phones_select_policy" ON owner_phones
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- ALL policy for service_role
CREATE POLICY "owner_phones_service_role_policy" ON owner_phones
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Grant SELECT to anon and authenticated
GRANT SELECT ON owner_phones TO anon;
GRANT SELECT ON owner_phones TO authenticated;

-- Grant ALL to service_role
GRANT ALL ON owner_phones TO service_role;
;
