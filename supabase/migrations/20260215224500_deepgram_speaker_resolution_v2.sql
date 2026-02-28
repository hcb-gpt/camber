-- Deepgram diarization speaker resolution (SPEAKER_0/1 → contacts)
-- Problem: journal_claims speaker_label often contains generic Deepgram diarization labels
--          which cannot be resolved by name/alias matching alone.
-- Approach: infer diarization speaker role (owner vs other_party) using:
--           - calls_raw.direction (inbound/outbound)
--           - earliest-word speaker id from transcripts_comparison.words (engine=deepgram)
--           Then resolve to contacts via lookup_contact_by_phone (preferred) or owner/other_party name fallback.

-- ----------------------------------------------------------------------------
-- 1) Audit table (backfill + traceability)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.speaker_resolution_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_claim_row_id UUID NOT NULL,
  claim_id UUID,
  call_id TEXT NOT NULL,
  project_id UUID,
  speaker_label TEXT,
  old_speaker_contact_id UUID,
  new_speaker_contact_id UUID,
  new_speaker_is_internal BOOLEAN,
  match_quality INT,
  match_type TEXT,
  applied_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_speaker_resolution_audit_call_id
ON public.speaker_resolution_audit(call_id);
COMMENT ON TABLE public.speaker_resolution_audit IS
  'Audit log for speaker_contact_id backfills, especially Deepgram diarization SPEAKER_N labels.';
-- ----------------------------------------------------------------------------
-- 2) Resolve speaker label → contact (v2: call-aware Deepgram path)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_speaker_contact_v2(
  p_speaker_label TEXT,
  p_project_id UUID DEFAULT NULL,
  p_call_id TEXT DEFAULT NULL
)
RETURNS TABLE (
  contact_id UUID,
  contact_name TEXT,
  is_internal BOOLEAN,
  match_quality INT,
  match_type TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_label TEXT;
  v_speaker_num INT;
  v_direction TEXT;
  v_owner_phone TEXT;
  v_other_phone TEXT;
  v_owner_name TEXT;
  v_other_name TEXT;
  v_first_speaker INT;
  v_speaker_count INT;
  v_words JSONB;
  v_transcript TEXT;
  v_inferred_role TEXT; -- 'owner' | 'other_party'
BEGIN
  IF p_speaker_label IS NULL OR TRIM(p_speaker_label) = '' THEN
    RETURN;
  END IF;

  v_label := TRIM(p_speaker_label);

  -- Deepgram diarization speaker labels (SPEAKER_0, SPEAKER_1, ...)
  IF p_call_id IS NOT NULL AND v_label ~* '^SPEAKER_[0-9]+$' THEN
    v_speaker_num := NULLIF(regexp_replace(v_label, '[^0-9]', '', 'g'), '')::INT;

    -- Load call participant info
    SELECT
      cr.direction,
      cr.owner_phone,
      cr.other_party_phone,
      cr.owner_name,
      cr.other_party_name
    INTO
      v_direction,
      v_owner_phone,
      v_other_phone,
      v_owner_name,
      v_other_name
    FROM public.calls_raw cr
    WHERE cr.interaction_id = p_call_id
    ORDER BY
      cr.event_at_utc DESC NULLS LAST,
      cr.ingested_at_utc DESC NULLS LAST,
      cr.received_at_utc DESC NULLS LAST,
      cr.id DESC
    LIMIT 1;

    IF v_owner_phone IS NULL AND v_other_phone IS NULL AND v_owner_name IS NULL AND v_other_name IS NULL THEN
      RETURN;
    END IF;

    -- Determine speaker_count (prefer persisted) + first_speaker (prefer words; fallback transcript lines)
    SELECT
      tc.speaker_count,
      tc.words,
      tc.transcript
    INTO v_speaker_count, v_words, v_transcript
    FROM public.transcripts_comparison tc
    WHERE tc.interaction_id = p_call_id
      AND tc.engine = 'deepgram'
    ORDER BY
      tc.created_at DESC NULLS LAST,
      tc.id DESC
    LIMIT 1;

    -- Compute speaker_count if not persisted
    IF v_speaker_count IS NULL THEN
      IF v_words IS NOT NULL THEN
        SELECT COUNT(DISTINCT (w2->>'speaker')::INT)
        INTO v_speaker_count
        FROM jsonb_array_elements(v_words) w2
        WHERE w2 ? 'speaker';
      ELSIF v_transcript IS NOT NULL THEN
        SELECT COUNT(DISTINCT (m[1])::INT)
        INTO v_speaker_count
        FROM regexp_matches(v_transcript, '(?m)^SPEAKER_([0-9]+):', 'g') AS m;
      END IF;
    END IF;

    -- Prefer word-level timings for first speaker
    IF v_words IS NOT NULL THEN
      SELECT (w->>'speaker')::INT
      INTO v_first_speaker
      FROM jsonb_array_elements(v_words) w
      WHERE w ? 'speaker' AND w ? 'start'
      ORDER BY (w->>'start')::NUMERIC ASC
      LIMIT 1;
    END IF;

    -- Fallback: parse first transcript line label (Deepgram utterances are chronological)
    IF v_first_speaker IS NULL AND v_transcript IS NOT NULL THEN
      v_first_speaker := NULLIF((regexp_match(v_transcript, '(?m)^SPEAKER_([0-9]+):'))[1], '')::INT;
    END IF;

    -- Only handle the deterministic 2-speaker case.
    IF v_first_speaker IS NULL OR v_speaker_count IS NULL OR v_speaker_count != 2 THEN
      RETURN;
    END IF;

    -- Infer roles from direction + first speaker.
    -- Inbound: other party called owner → owner typically answers first.
    -- Outbound: owner called other party → other party typically answers first.
    IF v_direction ~* '^(in|inbound|incoming)' THEN
      v_inferred_role := CASE WHEN v_speaker_num = v_first_speaker THEN 'owner' ELSE 'other_party' END;
    ELSIF v_direction ~* '^(out|outbound|outgoing)' THEN
      v_inferred_role := CASE WHEN v_speaker_num = v_first_speaker THEN 'other_party' ELSE 'owner' END;
    ELSE
      -- No reliable direction → do not guess.
      RETURN;
    END IF;

    -- Preferred: resolve by phone (pipeline-normalized via lookup_contact_by_phone).
    IF v_inferred_role = 'owner' AND v_owner_phone IS NOT NULL THEN
      RETURN QUERY
      SELECT
        l.contact_id,
        l.contact_name,
        (l.contact_type = 'internal') AS is_internal,
        88 AS match_quality,
        'deepgram_role_phone_owner'::TEXT AS match_type
      FROM public.lookup_contact_by_phone(v_owner_phone) l
      LIMIT 1;

      IF FOUND THEN RETURN; END IF;
    END IF;

    IF v_inferred_role = 'other_party' AND v_other_phone IS NOT NULL THEN
      RETURN QUERY
      SELECT
        l.contact_id,
        l.contact_name,
        (l.contact_type = 'internal') AS is_internal,
        86 AS match_quality,
        'deepgram_role_phone_other_party'::TEXT AS match_type
      FROM public.lookup_contact_by_phone(v_other_phone) l
      LIMIT 1;

      IF FOUND THEN RETURN; END IF;
    END IF;

    -- Fallback: resolve by call participant names (best-effort).
    IF v_inferred_role = 'owner' AND v_owner_name IS NOT NULL AND TRIM(v_owner_name) != '' THEN
      RETURN QUERY
      SELECT
        r.contact_id,
        r.contact_name,
        r.is_internal,
        LEAST(82, r.match_quality) AS match_quality,
        ('deepgram_role_name_owner+' || r.match_type)::TEXT AS match_type
      FROM public.resolve_speaker_contact(v_owner_name, p_project_id) r
      LIMIT 1;

      IF FOUND THEN RETURN; END IF;
    END IF;

    IF v_inferred_role = 'other_party' AND v_other_name IS NOT NULL AND TRIM(v_other_name) != '' THEN
      RETURN QUERY
      SELECT
        r.contact_id,
        r.contact_name,
        r.is_internal,
        LEAST(80, r.match_quality) AS match_quality,
        ('deepgram_role_name_other_party+' || r.match_type)::TEXT AS match_type
      FROM public.resolve_speaker_contact(v_other_name, p_project_id) r
      LIMIT 1;

      IF FOUND THEN RETURN; END IF;
    END IF;

    RETURN;
  END IF;

  -- Non-Deepgram labels: use existing resolution logic.
  RETURN QUERY
  SELECT *
  FROM public.resolve_speaker_contact(v_label, p_project_id);
END;
$$;
GRANT EXECUTE ON FUNCTION public.resolve_speaker_contact_v2(TEXT, UUID, TEXT) TO service_role;
REVOKE EXECUTE ON FUNCTION public.resolve_speaker_contact_v2(TEXT, UUID, TEXT) FROM anon, authenticated;
COMMENT ON FUNCTION public.resolve_speaker_contact_v2 IS
  'Resolve speaker_label → contact_id. v2 adds call-aware resolution for Deepgram diarization SPEAKER_N labels '
  'using calls_raw (direction/phones/names) + transcripts_comparison.words (earliest speaker).';
-- ----------------------------------------------------------------------------
-- 3) Update journal_claims trigger to use v2 (call-aware)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_journal_claim_speakers()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_speaker_result RECORD;
  v_reported_by_result RECORD;
  v_project_id UUID;
BEGIN
  v_project_id := COALESCE(NEW.claim_project_id, NEW.project_id);

  -- Resolve speaker_label if present and not already resolved
  IF NEW.speaker_label IS NOT NULL AND NEW.speaker_contact_id IS NULL THEN
    SELECT * INTO v_speaker_result
    FROM public.resolve_speaker_contact_v2(NEW.speaker_label, v_project_id, NEW.call_id);

    IF v_speaker_result.contact_id IS NOT NULL THEN
      NEW.speaker_contact_id := v_speaker_result.contact_id;
      NEW.speaker_is_internal := v_speaker_result.is_internal;
    END IF;
  END IF;

  -- Resolve reported_by_label if present and not already resolved
  IF NEW.reported_by_label IS NOT NULL AND NEW.reported_by_contact_id IS NULL THEN
    SELECT * INTO v_reported_by_result
    FROM public.resolve_speaker_contact_v2(NEW.reported_by_label, v_project_id, NEW.call_id);

    IF v_reported_by_result.contact_id IS NOT NULL THEN
      NEW.reported_by_contact_id := v_reported_by_result.contact_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
-- Recreate trigger (idempotent)
DROP TRIGGER IF EXISTS trg_resolve_journal_claim_speakers ON public.journal_claims;
CREATE TRIGGER trg_resolve_journal_claim_speakers
  BEFORE INSERT OR UPDATE ON public.journal_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.resolve_journal_claim_speakers();
COMMENT ON FUNCTION public.resolve_journal_claim_speakers IS
  'Auto-resolves speaker_label and reported_by_label to contact_ids on journal_claims insert/update. '
  'v2: uses resolve_speaker_contact_v2 (call-aware Deepgram diarization handling).';
