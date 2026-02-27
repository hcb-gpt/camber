-- Sync canonical redline view definitions from production and expose
-- pending attribution metadata on thread surfaces.

CREATE OR REPLACE VIEW redline_contact_thread AS
SELECT
  i.id AS interaction_id,
  i.event_at_utc,
  i.event_at_local,
  i.channel AS interaction_type,
  cr.direction,
  i.contact_id,
  i.contact_name,
  i.contact_phone,
  NULL::integer AS duration_seconds,
  i.human_summary AS summary,
  cs.id AS span_id,
  cs.span_index,
  cs.transcript_segment,
  jc.speaker_label,
  jc.speaker_contact_id,
  jc.id AS claim_id,
  jc.claim_type,
  jc.claim_text,
  jc.span_text,
  jc.claim_confirmation_state AS confirmation_state,
  cg.id AS grade_id,
  cg.grade,
  cg.correction_text,
  cg.graded_by,
  cg.graded_at,
  rq_pending.id AS review_queue_id,
  (rq_pending.id IS NOT NULL) AS needs_attribution
FROM interactions i
LEFT JOIN calls_raw cr
  ON cr.interaction_id = i.interaction_id
LEFT JOIN journal_claims jc
  ON jc.call_id = i.interaction_id
LEFT JOIN conversation_spans cs
  ON cs.id = jc.source_span_id
  AND cs.is_superseded = false
LEFT JOIN claim_grades cg
  ON cg.claim_id = jc.id
LEFT JOIN LATERAL (
  SELECT
    rq.id,
    rq.created_at
  FROM review_queue rq
  WHERE rq.status = 'pending'
    AND rq.span_id = cs.id
  ORDER BY rq.created_at DESC
  LIMIT 1
) rq_pending
  ON true
WHERE i.contact_id IS NOT NULL
ORDER BY i.event_at_utc DESC, cs.span_index;

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
  rq_pending.span_id AS span_id,
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
  NULL::timestamp with time zone AS graded_at,
  rq_pending.id AS review_queue_id,
  (rq_pending.id IS NOT NULL) AS needs_attribution
FROM sms_messages s
LEFT JOIN contacts c
  ON c.phone = s.contact_phone
LEFT JOIN LATERAL (
  SELECT
    rq.id,
    rq.span_id,
    rq.created_at
  FROM review_queue rq
  WHERE rq.status = 'pending'
    AND rq.interaction_id IN (
      'sms_thread_' || regexp_replace(COALESCE(s.contact_phone, ''), '\D', '', 'g') || '_' ||
        floor(EXTRACT(epoch FROM s.sent_at))::bigint::text,
      'sms_thread__' || floor(EXTRACT(epoch FROM s.sent_at))::bigint::text
    )
  ORDER BY rq.created_at DESC
  LIMIT 1
) rq_pending
  ON true
WHERE EXISTS (
  SELECT 1
  FROM sms_messages s2
  WHERE s2.contact_phone = s.contact_phone
    AND s2.direction = 'inbound'::text
);

CREATE OR REPLACE VIEW redline_thread AS
SELECT
  rct.interaction_id,
  rct.event_at_utc,
  rct.event_at_local,
  rct.interaction_type,
  rct.direction,
  rct.contact_id,
  rct.contact_name,
  rct.contact_phone,
  rct.duration_seconds,
  rct.summary,
  rct.span_id,
  rct.span_index,
  rct.transcript_segment,
  rct.speaker_label,
  rct.speaker_contact_id,
  rct.claim_id,
  rct.claim_type,
  rct.claim_text,
  rct.span_text,
  rct.confirmation_state,
  rct.grade_id,
  rct.grade,
  rct.correction_text,
  rct.graded_by,
  rct.graded_at,
  rct.review_queue_id,
  rct.needs_attribution
FROM redline_contact_thread rct
UNION ALL
SELECT
  rst.sms_id AS interaction_id,
  rst.event_at_utc,
  rst.event_at_local,
  rst.interaction_type,
  rst.direction,
  rst.contact_id,
  rst.contact_name,
  rst.contact_phone,
  rst.duration_seconds,
  rst.summary,
  rst.span_id,
  rst.span_index,
  rst.transcript_segment,
  rst.speaker_label,
  rst.speaker_contact_id,
  rst.claim_id,
  rst.claim_type,
  rst.claim_text,
  rst.span_text,
  rst.confirmation_state,
  rst.grade_id,
  rst.grade,
  rst.correction_text,
  rst.graded_by,
  rst.graded_at,
  rst.review_queue_id,
  rst.needs_attribution
FROM redline_sms_thread rst
ORDER BY event_at_utc DESC;

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
  JOIN contacts c
    ON c.phone = s.contact_phone
  WHERE EXISTS (
    SELECT 1
    FROM sms_messages s2
    WHERE s2.contact_phone = s.contact_phone
      AND s2.direction = 'inbound'::text
  )
    AND NOT (
      s.contact_phone IN (
        SELECT owner_phones.phone
        FROM owner_phones
        WHERE owner_phones.active = true
      )
    )
  GROUP BY c.id
),
grading_cutoff AS (
  SELECT COALESCE(
    (
      SELECT redline_settings.value_timestamptz
      FROM redline_settings
      WHERE redline_settings.key = 'grading_cutoff'::text
    ),
    '1970-01-01 00:00:00+00'::timestamp with time zone
  ) AS cutoff
),
claim_stats AS (
  SELECT
    i.contact_id,
    count(DISTINCT jc.id) AS claim_count,
    count(DISTINCT jc.id) FILTER (
      WHERE jc.created_at >= (SELECT grading_cutoff.cutoff FROM grading_cutoff)
        AND NOT EXISTS (
          SELECT 1
          FROM claim_grades cg2
          WHERE cg2.claim_id = jc.id
            AND cg2.graded_at >= (SELECT grading_cutoff.cutoff FROM grading_cutoff)
        )
    ) AS ungraded_count
  FROM interactions i
  JOIN journal_claims jc
    ON jc.call_id = i.interaction_id
  WHERE i.contact_id IS NOT NULL
  GROUP BY i.contact_id
),
pending_review AS (
  SELECT
    COALESCE(i.contact_id, c_match.id) AS contact_id,
    rq.id AS queue_id
  FROM review_queue rq
  JOIN interactions i
    ON i.interaction_id = rq.interaction_id
  LEFT JOIN LATERAL (
    SELECT c.id
    FROM contacts c
    WHERE i.contact_id IS NULL
      AND i.contact_name IS NOT NULL
      AND c.name = i.contact_name
    ORDER BY c.updated_at DESC NULLS LAST, c.id
    LIMIT 1
  ) c_match
    ON true
  WHERE rq.status = 'pending'::text
    AND rq.created_at >= (SELECT grading_cutoff.cutoff FROM grading_cutoff)
),
review_stats AS (
  SELECT
    pending_review.contact_id,
    count(DISTINCT pending_review.queue_id) AS ungraded_count
  FROM pending_review
  WHERE pending_review.contact_id IS NOT NULL
  GROUP BY pending_review.contact_id
),
last_call AS (
  SELECT DISTINCT ON (i.contact_id)
    i.contact_id,
    left(i.human_summary, 80) AS snippet,
    cr.direction,
    'call'::text AS interaction_type,
    i.event_at_utc
  FROM interactions i
  LEFT JOIN calls_raw cr
    ON cr.interaction_id = i.interaction_id
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
  JOIN contacts c
    ON c.phone = s.contact_phone
  WHERE EXISTS (
    SELECT 1
    FROM sms_messages s2
    WHERE s2.contact_phone = s.contact_phone
      AND s2.direction = 'inbound'::text
  )
    AND NOT (
      s.contact_phone IN (
        SELECT owner_phones.phone
        FROM owner_phones
        WHERE owner_phones.active = true
      )
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
    SELECT
      last_call.contact_id,
      last_call.snippet,
      last_call.direction,
      last_call.interaction_type,
      last_call.event_at_utc
    FROM last_call
    UNION ALL
    SELECT
      last_sms.contact_id,
      last_sms.snippet,
      last_sms.direction,
      last_sms.interaction_type,
      last_sms.event_at_utc
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
  COALESCE(rs.ungraded_count, cls.ungraded_count, 0::bigint)::integer AS ungraded_count,
  GREATEST(cs.last_call_at, ss.last_sms_at) AS last_activity,
  lt.last_snippet,
  lt.last_direction,
  lt.last_interaction_type
FROM contacts c
LEFT JOIN call_stats cs
  ON cs.contact_id = c.id
LEFT JOIN sms_stats ss
  ON ss.contact_id = c.id
LEFT JOIN claim_stats cls
  ON cls.contact_id = c.id
LEFT JOIN review_stats rs
  ON rs.contact_id = c.id
LEFT JOIN latest lt
  ON lt.contact_id = c.id
WHERE COALESCE(cs.call_count, 0::bigint) > 0
   OR COALESCE(ss.sms_count, 0::bigint) > 0
ORDER BY GREATEST(cs.last_call_at, ss.last_sms_at) DESC NULLS LAST;
