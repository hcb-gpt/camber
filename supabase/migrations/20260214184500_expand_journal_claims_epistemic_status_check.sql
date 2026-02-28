-- Expand journal_claims epistemic_status vocabulary for upgraded extraction prompt.
-- Keep legacy values (stated/uncertain) temporarily for compatibility during rollout.

ALTER TABLE public.journal_claims
DROP CONSTRAINT IF EXISTS journal_claims_epistemic_status_check;
ALTER TABLE public.journal_claims
ADD CONSTRAINT journal_claims_epistemic_status_check
CHECK (
  epistemic_status = ANY (
    ARRAY[
      'observed'::text,
      'reported'::text,
      'inferred'::text,
      'promised'::text,
      'decided'::text,
      'disputed'::text,
      'superseded'::text,
      'stated'::text,
      'uncertain'::text
    ]
  )
);
COMMENT ON CONSTRAINT journal_claims_epistemic_status_check ON public.journal_claims IS
'Allowed epistemic statuses for extraction. Upgraded set plus legacy stated/uncertain during transition.';
