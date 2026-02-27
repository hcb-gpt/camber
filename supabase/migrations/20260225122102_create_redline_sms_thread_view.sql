-- Redline Step 2B: SMS bridge view — UNION-compatible with redline_contact_thread
-- Joins sms_messages to contacts via phone number match

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
  CASE WHEN s.direction = 'inbound' THEN s.contact_name ELSE 'Chad' END AS speaker_label,
  CASE WHEN s.direction = 'inbound' THEN c.id ELSE NULL END AS speaker_contact_id,
  NULL::uuid AS claim_id,
  NULL::text AS claim_type,
  NULL::text AS claim_text,
  NULL::text AS span_text,
  NULL::text AS confirmation_state,
  NULL::uuid AS grade_id,
  NULL::text AS grade,
  NULL::text AS correction_text,
  NULL::text AS graded_by,
  NULL::timestamptz AS graded_at
FROM sms_messages s
LEFT JOIN contacts c ON c.phone = s.contact_phone;

COMMENT ON VIEW redline_sms_thread IS 'Redline MVP: SMS messages joined to contacts via phone. UNION-compatible with redline_contact_thread for interleaved timeline.';;
