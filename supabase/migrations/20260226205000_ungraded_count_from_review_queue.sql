-- v2.9.4: Drive redline ungraded_count from pending review_queue items
--
-- Problem:
-- Contacts can show 0 ungraded even when new review work exists, because
-- journal_claims can lag while review_queue receives fresh span/thread items.
--
-- Fix:
-- Compute ungraded_count primarily from pending review_queue rows created
-- after grading_cutoff, with a contact_id fallback by contact_name when
-- interactions.contact_id is null (common for sms_thread rows).

CREATE OR REPLACE VIEW redline_contacts AS
 WITH call_stats AS (
         SELECT interactions.contact_id,
            count(*) AS call_count,
            max(interactions.event_at_utc) AS last_call_at
           FROM interactions
          WHERE interactions.contact_id IS NOT NULL
          GROUP BY interactions.contact_id
        ), sms_stats AS (
         SELECT c_1.id AS contact_id,
            count(*) AS sms_count,
            max(s.sent_at) AS last_sms_at
           FROM sms_messages s
             JOIN contacts c_1 ON c_1.phone = s.contact_phone
          WHERE (EXISTS ( SELECT 1
                   FROM sms_messages s2
                  WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'::text)) AND NOT (s.contact_phone IN ( SELECT owner_phones.phone
                   FROM owner_phones
                  WHERE owner_phones.active = true))
          GROUP BY c_1.id
        ), grading_cutoff AS (
         SELECT COALESCE(
           (SELECT value_timestamptz FROM redline_settings WHERE key = 'grading_cutoff'),
           '1970-01-01 00:00:00+00'::timestamptz
         ) AS cutoff
        ), claim_stats AS (
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
        ), pending_review AS (
         SELECT COALESCE(i.contact_id, c_match.id) AS contact_id,
            rq.id AS queue_id
           FROM review_queue rq
             JOIN interactions i ON i.interaction_id = rq.interaction_id
             LEFT JOIN LATERAL ( SELECT c.id
                   FROM contacts c
                  WHERE i.contact_id IS NULL AND i.contact_name IS NOT NULL AND c.name = i.contact_name
                  ORDER BY c.updated_at DESC NULLS LAST, c.id
                 LIMIT 1) c_match ON true
          WHERE rq.status = 'pending'::text AND rq.created_at >= (SELECT cutoff
                   FROM grading_cutoff)
        ), review_stats AS (
         SELECT pending_review.contact_id,
            count(DISTINCT pending_review.queue_id) AS ungraded_count
           FROM pending_review
          WHERE pending_review.contact_id IS NOT NULL
          GROUP BY pending_review.contact_id
        ), last_call AS (
         SELECT DISTINCT ON (i.contact_id) i.contact_id,
            left(i.human_summary, 80) AS snippet,
            cr.direction,
            'call'::text AS interaction_type,
            i.event_at_utc
           FROM interactions i
             LEFT JOIN calls_raw cr ON cr.interaction_id = i.interaction_id
          WHERE i.contact_id IS NOT NULL
          ORDER BY i.contact_id, i.event_at_utc DESC NULLS LAST
        ), last_sms AS (
         SELECT DISTINCT ON (c_1.id) c_1.id AS contact_id,
            left(s.content, 80) AS snippet,
            s.direction,
            'sms'::text AS interaction_type,
            s.sent_at AS event_at_utc
           FROM sms_messages s
             JOIN contacts c_1 ON c_1.phone = s.contact_phone
          WHERE (EXISTS ( SELECT 1
                   FROM sms_messages s2
                  WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'::text)) AND NOT (s.contact_phone IN ( SELECT owner_phones.phone
                   FROM owner_phones
                  WHERE owner_phones.active = true))
          ORDER BY c_1.id, s.sent_at DESC NULLS LAST
        ), latest AS (
         SELECT DISTINCT ON (combined.contact_id) combined.contact_id,
            combined.snippet AS last_snippet,
            combined.direction AS last_direction,
            combined.interaction_type AS last_interaction_type
           FROM ( SELECT last_call.contact_id,
                    last_call.snippet,
                    last_call.direction,
                    last_call.interaction_type,
                    last_call.event_at_utc
                   FROM last_call
                UNION ALL
                 SELECT last_sms.contact_id,
                    last_sms.snippet,
                    last_sms.direction,
                    last_sms.interaction_type,
                    last_sms.event_at_utc
                   FROM last_sms) combined
          ORDER BY combined.contact_id, combined.event_at_utc DESC NULLS LAST
        )
 SELECT c.id AS contact_id,
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
     LEFT JOIN call_stats cs ON cs.contact_id = c.id
     LEFT JOIN sms_stats ss ON ss.contact_id = c.id
     LEFT JOIN claim_stats cls ON cls.contact_id = c.id
     LEFT JOIN review_stats rs ON rs.contact_id = c.id
     LEFT JOIN latest lt ON lt.contact_id = c.id
  WHERE COALESCE(cs.call_count, 0::bigint) > 0 OR COALESCE(ss.sms_count, 0::bigint) > 0
  ORDER BY (GREATEST(cs.last_call_at, ss.last_sms_at)) DESC NULLS LAST;
;
