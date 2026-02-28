-- Fix NULL-safety bug in redline_sms_thread view.
--
-- Problem: WHERE EXISTS (s2.contact_phone = s.contact_phone) drops all
-- rows where contact_phone IS NULL because NULL = NULL evaluates to
-- UNKNOWN in SQL. This makes null-phone SMS messages invisible in the
-- thread view.
--
-- Fix: Use IS NOT DISTINCT FROM instead of = so NULL=NULL returns TRUE.
-- Thread: chad_barlow_sms_fix
-- Author: data-r2

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
  WHERE s2.contact_phone IS NOT DISTINCT FROM s.contact_phone
    AND s2.direction = 'inbound'::text
);

-- Also update redline_thread (union view) to pick up the fix.
-- redline_contact_thread is safe (uses contact_id IS NOT NULL filter).
-- redline_thread is a simple UNION ALL so it inherits the fix automatically
-- from redline_sms_thread. No change needed to redline_thread itself.
