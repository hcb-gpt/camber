
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
                  WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'::text))
            AND s.contact_phone NOT IN (SELECT phone FROM owner_phones WHERE active = true)
          GROUP BY c_1.id
        ), claim_stats AS (
         SELECT i.contact_id,
            count(DISTINCT jc.id) AS claim_count,
            count(DISTINCT jc.id) FILTER (WHERE cg.id IS NULL AND jc.created_at >= COALESCE(( SELECT redline_settings.value_timestamptz
                   FROM redline_settings
                  WHERE redline_settings.key = 'grading_cutoff'::text), '1970-01-01 00:00:00+00'::timestamp with time zone)) AS ungraded_count
           FROM interactions i
             JOIN journal_claims jc ON jc.call_id = i.interaction_id
             LEFT JOIN claim_grades cg ON cg.claim_id = jc.id
          WHERE i.contact_id IS NOT NULL
          GROUP BY i.contact_id
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
                  WHERE s2.contact_phone = s.contact_phone AND s2.direction = 'inbound'::text))
            AND s.contact_phone NOT IN (SELECT phone FROM owner_phones WHERE active = true)
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
  WHERE COALESCE(cs.call_count, 0::bigint) > 0 OR COALESCE(ss.sms_count, 0::bigint) > 0
  ORDER BY (GREATEST(cs.last_call_at, ss.last_sms_at)) DESC NULLS LAST;
;
