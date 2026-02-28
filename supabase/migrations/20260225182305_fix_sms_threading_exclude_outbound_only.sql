-- Fix: Exclude outbound-only SMS contacts from redline views
-- Problem: Zack Sittler has 38 outbound-only SMS that inflate his sms_count.
-- Rule: If a contact has ANY inbound SMS, include ALL. If ALL outbound, exclude.

-- 1. redline_sms_thread
CREATE OR REPLACE VIEW redline_sms_thread AS
SELECT
  s.id AS sms_id,
  s.sent_at AS event_at_utc,
  s.sent_at AS event_at_local,
  'sms'::text AS interaction_type,
  s.direction,
  c.id AS contact_id,
  s.contact_name,
  s.contact_phone,
  NULL::integer AS duration_seconds,
  s.content AS summary,
  NULL::uuid AS span_id,
  NULL::integer AS span_index,
  s.content AS transcript_segment,
  CASE
    WHEN s.direction = 'inbound'::text THEN s.contact_name
    ELSE 'Chad'::text
  END AS speaker_label,
  CASE
    WHEN s.direction = 'inbound'::text THEN c.id
    ELSE NULL::uuid
  END AS speaker_contact_id,
  NULL::uuid AS claim_id,
  NULL::text AS claim_type,
  NULL::text AS claim_text,
  NULL::text AS span_text,
  NULL::text AS confirmation_state,
  NULL::uuid AS grade_id,
  NULL::text AS grade,
  NULL::text AS correction_text,
  NULL::text AS graded_by,
  NULL::timestamp with time zone AS graded_at
FROM sms_messages s
LEFT JOIN contacts c ON c.phone = s.contact_phone
WHERE EXISTS (
  SELECT 1 FROM sms_messages s2
  WHERE s2.contact_phone = s.contact_phone
    AND s2.direction = 'inbound'
);

-- 2. redline_contacts
CREATE OR REPLACE VIEW redline_contacts AS
WITH call_stats AS (
  SELECT
    interactions.contact_id,
    count(*) AS call_count,
    max(interactions.event_at_utc) AS last_call_at
  FROM interactions
  WHERE interactions.contact_id IS NOT NULL
  GROUP BY interactions.contact_id
),
sms_stats AS (
  SELECT
    c.id AS contact_id,
    count(*) AS sms_count,
    max(s.sent_at) AS last_sms_at
  FROM sms_messages s
  JOIN contacts c ON c.phone = s.contact_phone
  WHERE EXISTS (
    SELECT 1 FROM sms_messages s2
    WHERE s2.contact_phone = s.contact_phone
      AND s2.direction = 'inbound'
  )
  GROUP BY c.id
),
claim_stats AS (
  SELECT
    i.contact_id,
    count(DISTINCT jc.id) AS claim_count,
    count(DISTINCT jc.id) FILTER (WHERE cg.id IS NULL) AS ungraded_count
  FROM interactions i
  JOIN journal_claims jc ON jc.call_id = i.interaction_id
  LEFT JOIN claim_grades cg ON cg.claim_id = jc.id
  WHERE i.contact_id IS NOT NULL
  GROUP BY i.contact_id
),
last_call AS (
  SELECT DISTINCT ON (i.contact_id)
    i.contact_id,
    left(i.human_summary, 80) AS snippet,
    cr.direction,
    'call'::text AS interaction_type,
    i.event_at_utc
  FROM interactions i
  LEFT JOIN calls_raw cr ON cr.interaction_id = i.interaction_id
  WHERE i.contact_id IS NOT NULL
  ORDER BY i.contact_id, i.event_at_utc DESC NULLS LAST
),
last_sms AS (
  SELECT DISTINCT ON (c.id)
    c.id AS contact_id,
    left(s.content, 80) AS snippet,
    s.direction,
    'sms'::text AS interaction_type,
    s.sent_at AS event_at_utc
  FROM sms_messages s
  JOIN contacts c ON c.phone = s.contact_phone
  WHERE EXISTS (
    SELECT 1 FROM sms_messages s2
    WHERE s2.contact_phone = s.contact_phone
      AND s2.direction = 'inbound'
  )
  ORDER BY c.id, s.sent_at DESC NULLS LAST
),
latest AS (
  SELECT DISTINCT ON (combined.contact_id)
    combined.contact_id,
    combined.snippet AS last_snippet,
    combined.direction AS last_direction,
    combined.interaction_type AS last_interaction_type
  FROM (
    SELECT contact_id, snippet, direction, interaction_type, event_at_utc
    FROM last_call
    UNION ALL
    SELECT contact_id, snippet, direction, interaction_type, event_at_utc
    FROM last_sms
  ) combined
  ORDER BY combined.contact_id, combined.event_at_utc DESC NULLS LAST
)
SELECT
  c.id AS contact_id,
  c.name AS contact_name,
  c.phone AS contact_phone,
  COALESCE(cs.call_count, 0::bigint)::integer AS call_count,
  COALESCE(ss.sms_count, 0::bigint)::integer AS sms_count,
  COALESCE(cls.claim_count, 0::bigint)::integer AS claim_count,
  COALESCE(cls.ungraded_count, 0::bigint)::integer AS ungraded_count,
  GREATEST(cs.last_call_at, ss.last_sms_at) AS last_activity,
  lt.last_snippet,
  lt.last_direction,
  lt.last_interaction_type
FROM contacts c
LEFT JOIN call_stats cs ON cs.contact_id = c.id
LEFT JOIN sms_stats ss ON ss.contact_id = c.id
LEFT JOIN claim_stats cls ON cls.contact_id = c.id
LEFT JOIN latest lt ON lt.contact_id = c.id
WHERE COALESCE(cs.call_count, 0::bigint) > 0
   OR COALESCE(ss.sms_count, 0::bigint) > 0
ORDER BY GREATEST(cs.last_call_at, ss.last_sms_at) DESC NULLS LAST;;
