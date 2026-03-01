-- Beside parity alert remediation (v1):
-- 1) Backfill recent Beside call events into calls_raw (non-test only)
-- 2) Rework parity monitor views to reduce false positives and track actionable gaps

CREATE OR REPLACE FUNCTION public.seed_calls_raw_from_beside_calls_24h(
  p_limit integer DEFAULT 200,
  p_hours integer DEFAULT 24
)
RETURNS TABLE (
  scanned_count integer,
  inserted_count integer,
  inserted_interaction_ids text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH bounded AS (
    SELECT
      LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000) AS row_limit,
      LEAST(GREATEST(COALESCE(p_hours, 24), 1), 168) AS hour_window
  ),
  candidate AS (
    SELECT
      COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      ) AS interaction_id,
      b.beside_room_id AS thread_key,
      b.direction,
      b.contact_phone_e164 AS other_party_phone,
      b.occurred_at_utc AS event_at_utc,
      b.occurred_at_utc AS event_at_local,
      NULLIF(COALESCE(b.summary, b.text, ''), '') AS summary,
      b.payload_json AS raw_snapshot_json,
      COALESCE(b.ingested_at_utc, now()) AS ingested_at_utc,
      COALESCE(NULLIF(b.source, ''), 'beside_direct_read') AS capture_source
    FROM public.beside_thread_events b
    CROSS JOIN bounded x
    WHERE lower(COALESCE(b.beside_event_type, '')) LIKE 'call%'
      AND b.occurred_at_utc >= now() - make_interval(hours => x.hour_window)
      AND COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      ) IS NOT NULL
      AND lower(COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      )) NOT LIKE '%test%'
      AND lower(COALESCE(b.beside_event_id, '')) NOT LIKE '%test%'
      AND lower(COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      )) NOT LIKE '%synth%'
      AND lower(COALESCE(b.beside_event_id, '')) NOT LIKE '%synth%'
      AND lower(COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      )) NOT LIKE 'reconcile_test_%'
      AND lower(COALESCE(
        NULLIF(b.camber_interaction_id, ''),
        regexp_replace(b.beside_event_id, '^zapier_', '')
      )) NOT LIKE 'unknown_run_%'
      AND NOT EXISTS (
        SELECT 1
        FROM public.calls_raw cr
        WHERE cr.interaction_id = COALESCE(
          NULLIF(b.camber_interaction_id, ''),
          regexp_replace(b.beside_event_id, '^zapier_', '')
        )
      )
    ORDER BY b.occurred_at_utc DESC NULLS LAST, b.beside_event_id
    LIMIT (SELECT row_limit FROM bounded)
  ),
  ins AS (
    INSERT INTO public.calls_raw (
      interaction_id,
      channel,
      thread_key,
      direction,
      other_party_phone,
      event_at_utc,
      event_at_local,
      summary,
      raw_snapshot_json,
      ingested_at_utc,
      capture_source,
      is_shadow
    )
    SELECT
      c.interaction_id,
      'call',
      c.thread_key,
      c.direction,
      c.other_party_phone,
      c.event_at_utc,
      c.event_at_local,
      c.summary,
      c.raw_snapshot_json,
      c.ingested_at_utc,
      c.capture_source,
      false
    FROM candidate c
    ON CONFLICT (interaction_id) DO NOTHING
    RETURNING interaction_id
  ),
  scanned AS (
    SELECT COUNT(*)::integer AS scanned_count
    FROM candidate
  ),
  inserted AS (
    SELECT
      COUNT(*)::integer AS inserted_count,
      COALESCE(array_agg(interaction_id), ARRAY[]::text[]) AS inserted_interaction_ids
    FROM ins
  )
  SELECT
    scanned.scanned_count,
    inserted.inserted_count,
    inserted.inserted_interaction_ids
  FROM scanned, inserted;
END;
$$;

COMMENT ON FUNCTION public.seed_calls_raw_from_beside_calls_24h(integer, integer) IS
  'Backfills recent Beside call events into calls_raw (filters test/probe ids, idempotent on interaction_id).';

GRANT EXECUTE ON FUNCTION public.seed_calls_raw_from_beside_calls_24h(integer, integer) TO service_role;

CREATE OR REPLACE VIEW public.v_beside_calls_missing_in_interactions_24h AS
WITH beside_calls AS (
  SELECT
    b.beside_event_id,
    b.beside_event_type,
    b.occurred_at_utc,
    b.ingested_at_utc,
    b.source,
    COALESCE(
      NULLIF(b.camber_interaction_id, ''),
      regexp_replace(b.beside_event_id, '^zapier_', '')
    ) AS interaction_id,
    right(regexp_replace(COALESCE(b.contact_phone_e164, ''), '\D', '', 'g'), 10) AS phone10
  FROM public.beside_thread_events b
  WHERE lower(COALESCE(b.beside_event_type, '')) LIKE 'call%'
    AND b.occurred_at_utc >= now() - interval '24 hours'
),
filtered AS (
  SELECT *
  FROM beside_calls
  WHERE NULLIF(COALESCE(interaction_id, ''), '') IS NOT NULL
    AND lower(COALESCE(interaction_id, '')) NOT LIKE '%test%'
    AND lower(COALESCE(beside_event_id, '')) NOT LIKE '%test%'
    AND lower(COALESCE(interaction_id, '')) NOT LIKE '%synth%'
    AND lower(COALESCE(beside_event_id, '')) NOT LIKE '%synth%'
    AND lower(COALESCE(interaction_id, '')) NOT LIKE 'reconcile_test_%'
    AND lower(COALESCE(interaction_id, '')) NOT LIKE 'unknown_run_%'
),
missing AS (
  SELECT
    f.beside_event_id,
    f.beside_event_type,
    f.occurred_at_utc,
    f.ingested_at_utc AS beside_ingested_at_utc,
    f.source AS beside_source,
    f.phone10,
    f.interaction_id AS camber_interaction_id
  FROM filtered f
  LEFT JOIN public.interactions i
    ON i.interaction_id = f.interaction_id
   AND lower(COALESCE(i.channel, '')) IN ('call', 'phone')
   AND COALESCE(i.is_shadow, false) = false
  WHERE i.id IS NULL
),
ranked AS (
  SELECT
    m.*,
    row_number() OVER (ORDER BY m.occurred_at_utc DESC, m.beside_event_id) AS rn
  FROM missing m
)
SELECT
  now() AS generated_at_utc,
  now() - interval '24 hours' AS window_start_utc,
  COUNT(*)::integer AS missing_count,
  COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'beside_event_id', beside_event_id,
        'beside_event_type', beside_event_type,
        'phone10', phone10,
        'occurred_at_utc', occurred_at_utc,
        'beside_ingested_at_utc', beside_ingested_at_utc,
        'source', beside_source,
        'camber_interaction_id', camber_interaction_id
      )
      ORDER BY occurred_at_utc DESC
    ) FILTER (WHERE rn <= 20),
    '[]'::jsonb
  ) AS example_tuples,
  COALESCE(
    jsonb_agg(to_jsonb(camber_interaction_id) ORDER BY occurred_at_utc DESC)
      FILTER (WHERE rn <= 5),
    '[]'::jsonb
  ) AS sample_interaction_ids
FROM ranked;

COMMENT ON VIEW public.v_beside_calls_missing_in_interactions_24h IS
  '24h actionable Beside call events missing in non-shadow interactions; excludes test/probe ids and maps zapier_* ids to canonical interaction ids.';

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

COMMENT ON VIEW public.v_interactions_missing_in_redline_thread_24h IS
  '24h non-shadow call interactions not currently mappable to Redline contacts/thread by contact_id or phone10; excludes test/probe ids.';

GRANT SELECT ON public.v_beside_calls_missing_in_interactions_24h TO service_role;
GRANT SELECT ON public.v_interactions_missing_in_redline_thread_24h TO service_role;
