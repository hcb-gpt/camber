-- Extend redline_contacts: add last_snippet, last_direction, last_interaction_type
-- Uses DISTINCT ON to get the single most recent call + SMS per contact,
-- then picks the overall winner via a second DISTINCT ON

CREATE OR REPLACE VIEW public.redline_contacts AS
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
),
last_call AS (
  SELECT DISTINCT ON (i.contact_id)
    i.contact_id,
    LEFT(i.human_summary, 80) AS snippet,
    cr.direction,
    'call'::text AS interaction_type,
    i.event_at_utc
  FROM interactions i
  LEFT JOIN calls_raw cr ON cr.interaction_id = i.interaction_id
  WHERE i.contact_id IS NOT NULL
  ORDER BY i.contact_id, i.event_at_utc DESC
),
last_sms AS (
  SELECT DISTINCT ON (c.id)
    c.id AS contact_id,
    LEFT(s.content, 80) AS snippet,
    s.direction,
    'sms'::text AS interaction_type,
    s.sent_at AS event_at_utc
  FROM sms_messages s
  INNER JOIN contacts c ON c.phone = s.contact_phone
  ORDER BY c.id, s.sent_at DESC
),
latest AS (
  SELECT DISTINCT ON (contact_id)
    contact_id,
    snippet AS last_snippet,
    direction AS last_direction,
    interaction_type AS last_interaction_type
  FROM (
    SELECT * FROM last_call
    UNION ALL
    SELECT * FROM last_sms
  ) combined
  ORDER BY contact_id, event_at_utc DESC
)
SELECT
  c.id AS contact_id,
  c.name AS contact_name,
  c.phone AS contact_phone,
  COALESCE(cs.call_count, 0)::integer AS call_count,
  COALESCE(ss.sms_count, 0)::integer AS sms_count,
  COALESCE(cls.claim_count, 0)::integer AS claim_count,
  COALESCE(cls.ungraded_count, 0)::integer AS ungraded_count,
  GREATEST(cs.last_call_at, ss.last_sms_at) AS last_activity,
  lt.last_snippet,
  lt.last_direction,
  lt.last_interaction_type
FROM contacts c
LEFT JOIN call_stats cs ON cs.contact_id = c.id
LEFT JOIN sms_stats ss ON ss.contact_id = c.id
LEFT JOIN claim_stats cls ON cls.contact_id = c.id
LEFT JOIN latest lt ON lt.contact_id = c.id
WHERE COALESCE(cs.call_count, 0) > 0 OR COALESCE(ss.sms_count, 0) > 0
ORDER BY last_activity DESC NULLS LAST;;
