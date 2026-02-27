-- Fix: pending_review CTE in redline_contacts should NOT filter by grading_cutoff.
--
-- Problem: The grading clock reset (redline_settings.grading_cutoff) was hiding
-- pending attribution items (review_queue) in addition to claim grades. When the
-- user pressed "reset grading clock," all 133 pending attributions became invisible
-- because pending_review CTE had: WHERE rq.created_at >= cutoff.
--
-- Fix: Remove the grading_cutoff filter from pending_review. Attribution items
-- ("which project does this span belong to?") always need human attention
-- regardless of clock resets. The grading clock only affects claim grades
-- (confirm/reject/correct).
--
-- Thread: ios_sync_fix
-- Author: data-r2

CREATE OR REPLACE VIEW redline_contacts AS
WITH call_stats AS (
  SELECT contact_id, count(*) AS call_count, max(event_at_utc) AS last_call_at
  FROM interactions
  WHERE contact_id IS NOT NULL
  GROUP BY contact_id
),
sms_stats AS (
  SELECT c.id AS contact_id, count(*) AS sms_count, max(s.sent_at) AS last_sms_at
  FROM sms_messages s
  JOIN contacts c ON c.phone = s.contact_phone
  WHERE EXISTS (
    SELECT 1 FROM sms_messages s2
    WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'
  )
  AND s.contact_phone NOT IN (SELECT phone FROM owner_phones WHERE active = true)
  GROUP BY c.id
),
grading_cutoff AS (
  SELECT COALESCE(
    (SELECT value_timestamptz FROM redline_settings WHERE key = 'grading_cutoff'),
    '1970-01-01T00:00:00Z'::timestamptz
  ) AS cutoff
),
claim_stats AS (
  SELECT i.contact_id,
    count(DISTINCT jc.id) AS claim_count,
    count(DISTINCT jc.id) FILTER (
      WHERE jc.created_at >= (SELECT cutoff FROM grading_cutoff)
      AND NOT EXISTS (
        SELECT 1 FROM claim_grades cg2
        WHERE cg2.claim_id = jc.id
        AND cg2.graded_at >= (SELECT cutoff FROM grading_cutoff)
      )
    ) AS ungraded_count
  FROM interactions i
  JOIN journal_claims jc ON jc.call_id = i.interaction_id
  WHERE i.contact_id IS NOT NULL
  GROUP BY i.contact_id
),
pending_review AS (
  -- Attribution items: NO grading_cutoff filter.
  -- These always need human attention regardless of clock resets.
  SELECT COALESCE(i.contact_id, c_match.id) AS contact_id,
         rq.id AS queue_id
  FROM review_queue rq
  JOIN interactions i ON i.interaction_id = rq.interaction_id
  LEFT JOIN LATERAL (
    SELECT c.id
    FROM contacts c
    WHERE i.contact_id IS NULL
      AND i.contact_name IS NOT NULL
      AND c.name = i.contact_name
    ORDER BY c.updated_at DESC NULLS LAST, c.id
    LIMIT 1
  ) c_match ON true
  WHERE rq.status = 'pending'
),
review_stats AS (
  SELECT contact_id, count(DISTINCT queue_id) AS ungraded_count
  FROM pending_review
  WHERE contact_id IS NOT NULL
  GROUP BY contact_id
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
    WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'
  )
  AND s.contact_phone NOT IN (SELECT phone FROM owner_phones WHERE active = true)
  ORDER BY c.id, s.sent_at DESC NULLS LAST
),
latest AS (
  SELECT DISTINCT ON (combined.contact_id)
    combined.contact_id,
    combined.snippet AS last_snippet,
    combined.direction AS last_direction,
    combined.interaction_type AS last_interaction_type
  FROM (
    SELECT contact_id, snippet, direction, interaction_type, event_at_utc FROM last_call
    UNION ALL
    SELECT contact_id, snippet, direction, interaction_type, event_at_utc FROM last_sms
  ) combined
  ORDER BY combined.contact_id, combined.event_at_utc DESC NULLS LAST
)
SELECT
  c.id AS contact_id,
  c.name AS contact_name,
  c.phone AS contact_phone,
  COALESCE(cs.call_count, 0)::integer AS call_count,
  COALESCE(ss.sms_count, 0)::integer AS sms_count,
  COALESCE(cls.claim_count, 0)::integer AS claim_count,
  COALESCE(rs.ungraded_count, cls.ungraded_count, 0)::integer AS ungraded_count,
  GREATEST(cs.last_call_at, ss.last_sms_at) AS last_activity,
  lt.last_snippet,
  lt.last_direction,
  lt.last_interaction_type
FROM contacts c
LEFT JOIN call_stats cs ON cs.contact_id = c.id
LEFT JOIN sms_stats ss ON ss.contact_id = c.id
LEFT JOIN claim_stats cls ON cls.contact_id = c.id
LEFT JOIN review_stats rs ON rs.contact_id = c.id
LEFT JOIN latest lt ON lt.contact_id = c.id
WHERE COALESCE(cs.call_count, 0) > 0 OR COALESCE(ss.sms_count, 0) > 0
ORDER BY GREATEST(cs.last_call_at, ss.last_sms_at) DESC NULLS LAST;
