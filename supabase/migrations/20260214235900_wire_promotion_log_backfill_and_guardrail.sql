-- Ensure every promoted belief claim is auditable in promotion_log
-- and backfill historical promotions missing log rows.

CREATE OR REPLACE FUNCTION public.write_promotion_log_from_belief_claim()
RETURNS trigger
LANGUAGE plpgsql
AS $$
  DECLARE
    v_run_id uuid;
BEGIN
  IF NEW.journal_claim_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT run_id INTO v_run_id
  FROM public.journal_claims jc
  WHERE jc.id = NEW.journal_claim_id;

  v_run_id := COALESCE(NEW.source_run_id, v_run_id);

  IF v_run_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO promotion_log (claim_id, journal_claim_id, promoted_at, run_id)
  SELECT
    NEW.id,
    NEW.journal_claim_id,
    NEW.created_at,
    v_run_id
  WHERE NOT EXISTS (
    SELECT 1
    FROM promotion_log pl
    WHERE pl.claim_id = NEW.id
  );

  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_belief_claims_promotion_log ON public.belief_claims;
CREATE TRIGGER trg_belief_claims_promotion_log
  AFTER INSERT ON public.belief_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.write_promotion_log_from_belief_claim();
INSERT INTO promotion_log (claim_id, journal_claim_id, promoted_at, run_id)
SELECT
  bc.id,
  bc.journal_claim_id,
  COALESCE(bc.created_at, NOW()),
  COALESCE(bc.source_run_id, jc.run_id)
FROM public.belief_claims bc
JOIN public.journal_claims jc
  ON jc.id = bc.journal_claim_id
LEFT JOIN public.promotion_log pl
  ON pl.claim_id = bc.id
WHERE bc.journal_claim_id IS NOT NULL
  AND (bc.source_run_id IS NOT NULL OR jc.run_id IS NOT NULL)
  AND pl.id IS NULL;
-- Verification query (run after migration)
-- SELECT
--   (SELECT COUNT(*) FROM public.belief_claims WHERE journal_claim_id IS NOT NULL) AS belief_claims_with_journal_claim,
--   (SELECT COUNT(DISTINCT claim_id) FROM public.promotion_log) AS logged_promotions;;
