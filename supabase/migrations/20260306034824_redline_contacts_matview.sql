-- redline_contacts materialized view migration

-- Drop the existing view
DROP VIEW IF EXISTS public.redline_contacts;

-- Create the materialized view using the same logic
CREATE MATERIALIZED VIEW public.redline_contacts AS
WITH call_stats AS (
  SELECT
    contact_id,
    COUNT(*) AS call_count,
    MAX(event_at_utc) AS last_call_at
  FROM interactions
  WHERE contact_id IS NOT NULL
  GROUP BY contact_id
),
sms_stats AS (
  SELECT
    c.id AS contact_id,
    COUNT(*) AS sms_count,
    MAX(s.sent_at) AS last_sms_at
  FROM sms_messages s
  INNER JOIN contacts c ON c.phone = s.contact_phone
  GROUP BY c.id
),
claim_stats AS (
  SELECT
    i.contact_id,
    COUNT(DISTINCT jc.id) AS claim_count,
    COUNT(DISTINCT jc.id) FILTER (WHERE cg.id IS NULL) AS ungraded_count
  FROM interactions i
  INNER JOIN journal_claims jc ON jc.call_id = i.interaction_id
  LEFT JOIN claim_grades cg ON cg.claim_id = jc.id
  WHERE i.contact_id IS NOT NULL
  GROUP BY i.contact_id
)
SELECT
  c.id AS contact_id,
  c.name AS contact_name,
  c.phone AS contact_phone,
  COALESCE(cs.call_count, 0)::integer AS call_count,
  COALESCE(ss.sms_count, 0)::integer AS sms_count,
  COALESCE(cls.claim_count, 0)::integer AS claim_count,
  COALESCE(cls.ungraded_count, 0)::integer AS ungraded_count,
  GREATEST(cs.last_call_at, ss.last_sms_at) AS last_activity
FROM contacts c
LEFT JOIN call_stats cs ON cs.contact_id = c.id
LEFT JOIN sms_stats ss ON ss.contact_id = c.id
LEFT JOIN claim_stats cls ON cls.contact_id = c.id
WHERE COALESCE(cs.call_count, 0) > 0 OR COALESCE(ss.sms_count, 0) > 0
ORDER BY last_activity DESC NULLS LAST;

-- Create a unique index to allow CONCURRENTLY refreshes
CREATE UNIQUE INDEX idx_redline_contacts_contact_id ON public.redline_contacts(contact_id);

-- Grants
GRANT SELECT ON public.redline_contacts TO anon;
GRANT SELECT ON public.redline_contacts TO authenticated;

COMMENT ON MATERIALIZED VIEW public.redline_contacts IS 'Contacts list for Redline iOS MVP: per-contact call/SMS/claim counts with last activity timestamp';

-- Function to refresh the materialized view
CREATE OR REPLACE FUNCTION public.refresh_redline_contacts()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.redline_contacts;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
