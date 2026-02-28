-- Redline pipeline reconciliation + debug issue reporting surfaces

CREATE TABLE IF NOT EXISTS public.redline_data_issue_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  screen text NOT NULL,
  contact_id uuid NULL,
  phone text NULL,
  interaction_id text NULL,
  queue_id uuid NULL,
  request_id text NULL,
  contract_version text NULL,
  note text NULL,
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS redline_data_issue_reports_created_at_idx
  ON public.redline_data_issue_reports (created_at DESC);

CREATE INDEX IF NOT EXISTS redline_data_issue_reports_request_id_idx
  ON public.redline_data_issue_reports (request_id);

COMMENT ON TABLE public.redline_data_issue_reports IS
  'Debug reports from Redline app for data discrepancies and pipeline triage.';

CREATE OR REPLACE FUNCTION public.reconcile_calls_raw_to_interactions(p_limit integer DEFAULT 200)
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
  WITH candidate AS (
    SELECT
      cr.interaction_id,
      cr.channel,
      cr.zap_version,
      cr.owner_name,
      cr.owner_phone,
      cr.other_party_name,
      cr.other_party_phone,
      cr.thread_key,
      cr.event_at_utc,
      cr.event_at_local,
      cr.ingested_at_utc,
      cr.summary,
      cr.raw_snapshot_json,
      cr.bug_flags_json,
      cr.transcript,
      cr.is_shadow
    FROM public.calls_raw cr
    LEFT JOIN public.interactions i
      ON i.interaction_id = cr.interaction_id
    WHERE COALESCE(cr.is_shadow, false) = false
      AND NULLIF(COALESCE(cr.interaction_id, ''), '') IS NOT NULL
      AND cr.interaction_id NOT LIKE 'unknown_run_%'
      AND i.id IS NULL
    ORDER BY COALESCE(cr.event_at_utc, cr.ingested_at_utc) DESC NULLS LAST
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)
  ),
  mapped AS (
    SELECT
      c.interaction_id,
      COALESCE(NULLIF(c.channel, ''), 'call') AS channel,
      c.zap_version AS source_zap,
      c.owner_name,
      c.owner_phone,
      c.other_party_name AS contact_name,
      c.other_party_phone AS contact_phone,
      c.thread_key,
      c.event_at_utc,
      c.event_at_local,
      c.ingested_at_utc,
      c.summary AS human_summary,
      c.raw_snapshot_json AS future_proof_json,
      c.bug_flags_json,
      CASE
        WHEN COALESCE(c.transcript, '') = '' THEN NULL
        ELSE char_length(c.transcript)
      END AS transcript_chars,
      ct.id AS contact_id
    FROM candidate c
    LEFT JOIN public.contacts ct
      ON ct.phone_digits = regexp_replace(COALESCE(c.other_party_phone, ''), '[^0-9]', '', 'g')
  ),
  ins AS (
    INSERT INTO public.interactions (
      interaction_id,
      channel,
      source_zap,
      owner_name,
      owner_phone,
      contact_name,
      contact_phone,
      thread_key,
      event_at_utc,
      event_at_local,
      ingested_at_utc,
      human_summary,
      future_proof_json,
      bug_flags_json,
      transcript_chars,
      contact_id,
      is_shadow
    )
    SELECT
      m.interaction_id,
      m.channel,
      m.source_zap,
      m.owner_name,
      m.owner_phone,
      m.contact_name,
      m.contact_phone,
      m.thread_key,
      m.event_at_utc,
      m.event_at_local,
      m.ingested_at_utc,
      m.human_summary,
      m.future_proof_json,
      m.bug_flags_json,
      m.transcript_chars,
      m.contact_id,
      false
    FROM mapped m
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

COMMENT ON FUNCTION public.reconcile_calls_raw_to_interactions(integer) IS
  'Rebuilds missing interactions rows from calls_raw (idempotent by interaction_id existence check).';
