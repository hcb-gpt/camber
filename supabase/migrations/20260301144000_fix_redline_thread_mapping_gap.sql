-- Fix: Redline thread mapping gap — add is_shadow filter to contact_thread,
-- virtual contact_id to sms_thread, and repo-parity for parity monitor.
-- Matches deployed schema (review_queue_id, needs_attribution columns).
-- Directive: directive__fix_redline_thread_mapping_gap + v2 refinement
-- Session: dev-codex-13

BEGIN;

-- 1. redline_contact_thread: add is_shadow filter (deployed version has no shadow filter)
-- Preserves existing virtual contact_id CASE, review_queue LATERAL, contact_name COALESCE
CREATE OR REPLACE VIEW public.redline_contact_thread AS
SELECT
  i.id AS interaction_id,
  i.event_at_utc,
  i.event_at_local,
  i.channel AS interaction_type,
  cr.direction,
  CASE
    WHEN i.contact_id IS NOT NULL THEN i.contact_id
    WHEN i.contact_phone IS NOT NULL THEN md5('camber:beside_thread:' || i.contact_phone)::uuid
    ELSE '00000000-0000-0000-0000-000000000000'::uuid
  END AS contact_id,
  COALESCE(i.contact_name, i.contact_phone, 'Unknown'::text) AS contact_name,
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
FROM public.interactions i
LEFT JOIN public.calls_raw cr
  ON cr.interaction_id = i.interaction_id
LEFT JOIN public.journal_claims jc
  ON jc.call_id = i.interaction_id
LEFT JOIN public.conversation_spans cs
  ON cs.id = jc.source_span_id
  AND cs.is_superseded = false
LEFT JOIN public.claim_grades cg
  ON cg.claim_id = jc.id
LEFT JOIN LATERAL (
  SELECT rq.id, rq.created_at
  FROM public.review_queue rq
  WHERE rq.status = 'pending'
    AND rq.span_id = cs.id
  ORDER BY rq.created_at DESC
  LIMIT 1
) rq_pending ON true
WHERE COALESCE(i.is_shadow, false) = false
ORDER BY i.event_at_utc DESC, cs.span_index;

-- 2. redline_sms_thread: add virtual contact_id via COALESCE (currently uses raw c.id)
CREATE OR REPLACE VIEW public.redline_sms_thread AS
SELECT
  s.id AS sms_id,
  s.sent_at AS event_at_utc,
  s.sent_at AS event_at_local,
  'sms'::text AS interaction_type,
  s.direction,
  COALESCE(
    c.id,
    CASE
      WHEN s.contact_phone IS NOT NULL AND s.contact_phone <> ''
      THEN md5('camber:beside_thread:' || s.contact_phone)::uuid
      ELSE '00000000-0000-0000-0000-000000000000'::uuid
    END
  ) AS contact_id,
  s.contact_name,
  s.contact_phone,
  NULL::integer AS duration_seconds,
  s.content AS summary,
  rq_pending.span_id,
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
FROM public.sms_messages s
LEFT JOIN public.contacts c
  ON c.phone = s.contact_phone
LEFT JOIN LATERAL (
  SELECT
    rq.id,
    rq.span_id,
    rq.created_at
  FROM public.review_queue rq
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
  FROM public.sms_messages s2
  WHERE s2.contact_phone IS NOT DISTINCT FROM s.contact_phone
    AND s2.direction = 'inbound'::text
);

-- 3. v_interactions_missing_in_redline_thread_24h: repo parity for NULL/NULL exclusion
-- Deployed already has (contact_id IS NOT NULL OR contact_phone IS NOT NULL);
-- this is logically equivalent but uses NOT(...AND...) form for clarity.
CREATE OR REPLACE VIEW public.v_interactions_missing_in_redline_thread_24h AS
WITH interactions_calls AS (
  SELECT
    i.interaction_id,
    i.channel,
    i.event_at_utc,
    i.ingested_at_utc,
    i.contact_id,
    i.contact_name,
    i.contact_phone,
    right(regexp_replace(COALESCE(i.contact_phone, ''), '\D', '', 'g'), 10) AS phone10
  FROM public.interactions i
  WHERE lower(COALESCE(i.channel, '')) IN ('call', 'phone')
    AND COALESCE(i.is_shadow, false) = false
    AND i.event_at_utc >= now() - interval '24 hours'
    AND lower(COALESCE(i.interaction_id, '')) NOT LIKE '%test%'
    AND lower(COALESCE(i.interaction_id, '')) NOT LIKE '%synth%'
    AND i.interaction_id NOT LIKE 'reconcile_test_%'
    AND i.interaction_id NOT LIKE 'unknown_run_%'
    AND NOT (i.contact_id IS NULL AND i.contact_phone IS NULL)
)
SELECT
  now() AS generated_at_utc,
  i.interaction_id,
  i.channel,
  i.event_at_utc,
  i.ingested_at_utc,
  i.contact_id,
  i.contact_name,
  i.contact_phone
FROM interactions_calls i
WHERE NOT EXISTS (
  SELECT 1
  FROM public.redline_contacts_unified rc
  WHERE (i.contact_id IS NOT NULL AND rc.contact_id = i.contact_id)
     OR (
       i.phone10 <> ''
       AND right(regexp_replace(COALESCE(rc.contact_phone, ''), '\D', '', 'g'), 10) = i.phone10
     )
)
ORDER BY i.event_at_utc DESC, i.interaction_id;

COMMIT;
