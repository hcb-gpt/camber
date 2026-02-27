-- Prevent duplicate active claims on journal-extract reruns.
-- Strategy: normalize NULL claim_project_id to a sentinel UUID via a generated column,
-- then enforce uniqueness on (call_id, claim_type, claim_text, normalized_project_id) for active rows.

ALTER TABLE public.journal_claims
ADD COLUMN IF NOT EXISTS source_span_id UUID;
ALTER TABLE public.journal_claims
ADD COLUMN IF NOT EXISTS extraction_model_id TEXT,
ADD COLUMN IF NOT EXISTS extraction_prompt_version TEXT;
ALTER TABLE public.journal_claims
ADD COLUMN IF NOT EXISTS claim_project_id_norm UUID
GENERATED ALWAYS AS (
  COALESCE(claim_project_id, '00000000-0000-0000-0000-000000000000'::uuid)
) STORED;
CREATE INDEX IF NOT EXISTS idx_journal_claims_source_span_id
ON public.journal_claims (source_span_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_journal_claims_unique_active_dedup
ON public.journal_claims (call_id, claim_type, claim_text, claim_project_id_norm)
WHERE active = true;
CREATE OR REPLACE FUNCTION public.insert_journal_claims_dedup(p_rows jsonb)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  WITH rows AS (
    SELECT *
    FROM jsonb_to_recordset(p_rows) AS r(
      claim_id uuid,
      run_id uuid,
      call_id text,
      project_id uuid,
      source_span_id uuid,
      claim_type text,
      claim_text text,
      epistemic_status text,
      warrant_level text,
      testimony_type text,
      speaker_label text,
      speaker_contact_id uuid,
      speaker_is_internal boolean,
      start_sec numeric,
      end_sec numeric,
      relationship text,
      active boolean,
      extraction_model_id text,
      extraction_prompt_version text
    )
  ),
  ins AS (
    INSERT INTO public.journal_claims (
      claim_id,
      run_id,
      call_id,
      project_id,
      source_span_id,
      claim_type,
      claim_text,
      epistemic_status,
      warrant_level,
      testimony_type,
      speaker_label,
      speaker_contact_id,
      speaker_is_internal,
      start_sec,
      end_sec,
      relationship,
      active,
      extraction_model_id,
      extraction_prompt_version
    )
    SELECT
      r.claim_id,
      r.run_id,
      r.call_id,
      r.project_id,
      r.source_span_id,
      r.claim_type,
      r.claim_text,
      r.epistemic_status,
      r.warrant_level,
      r.testimony_type,
      r.speaker_label,
      r.speaker_contact_id,
      r.speaker_is_internal,
      r.start_sec,
      r.end_sec,
      r.relationship,
      COALESCE(r.active, true),
      r.extraction_model_id,
      r.extraction_prompt_version
    FROM rows r
    ON CONFLICT (call_id, claim_type, claim_text, claim_project_id_norm)
      WHERE active = true
    DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*) INTO inserted_count FROM ins;

  RETURN inserted_count;
END;
$$;
