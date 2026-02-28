CREATE OR REPLACE VIEW redline_contacts_unified AS
SELECT rc.contact_id,
    rc.contact_name,
    rc.contact_phone,
    rc.call_count,
    rc.sms_count,
    rc.claim_count,
    rc.ungraded_count,
    rc.last_activity,
    rc.last_snippet,
    rc.last_direction,
    rc.last_interaction_type,
    'contacts'::text AS source
   FROM redline_contacts rc
UNION ALL
 SELECT md5('camber:beside_thread:'::text || bt.contact_phone_e164)::uuid AS contact_id,
    bt.contact_phone_e164 AS contact_name,
    bt.contact_phone_e164 AS contact_phone,
    0 AS call_count,
    COALESCE(sms_agg.sms_count, 0) AS sms_count,
    0 AS claim_count,
    0 AS ungraded_count,
    bt.updated_at_utc AS last_activity,
    last_msg.content AS last_snippet,
    COALESCE(last_msg.direction, 'inbound') AS last_direction,
    'beside_thread'::text AS last_interaction_type,
    'beside_thread'::text AS source
   FROM beside_threads bt
     LEFT JOIN LATERAL ( SELECT count(*)::integer AS sms_count
           FROM sms_messages sm
          WHERE "right"(regexp_replace(COALESCE(sm.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) = "right"(regexp_replace(COALESCE(bt.contact_phone_e164, ''::text), '\D'::text, ''::text, 'g'::text), 10) AND "right"(regexp_replace(COALESCE(sm.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) <> ''::text) sms_agg ON true
     LEFT JOIN LATERAL ( SELECT sm2.direction, sm2.content
           FROM sms_messages sm2
          WHERE "right"(regexp_replace(COALESCE(sm2.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) = "right"(regexp_replace(COALESCE(bt.contact_phone_e164, ''::text), '\D'::text, ''::text, 'g'::text), 10) AND "right"(regexp_replace(COALESCE(sm2.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) <> ''::text
          ORDER BY sm2.sent_at DESC NULLS LAST
         LIMIT 1) last_msg ON true
  WHERE bt.contact_phone_e164 IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM redline_contacts rc2
          WHERE "right"(regexp_replace(COALESCE(rc2.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) = "right"(regexp_replace(COALESCE(bt.contact_phone_e164, ''::text), '\D'::text, ''::text, 'g'::text), 10) AND "right"(regexp_replace(COALESCE(rc2.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) <> ''::text)) AND bt.beside_room_id = (( SELECT bt2.beside_room_id
           FROM beside_threads bt2
          WHERE bt2.contact_phone_e164 IS NOT NULL AND "right"(regexp_replace(COALESCE(bt2.contact_phone_e164, ''::text), '\D'::text, ''::text, 'g'::text), 10) = "right"(regexp_replace(COALESCE(bt.contact_phone_e164, ''::text), '\D'::text, ''::text, 'g'::text), 10)
          ORDER BY bt2.updated_at_utc DESC NULLS LAST, bt2.beside_room_id
         LIMIT 1));;
