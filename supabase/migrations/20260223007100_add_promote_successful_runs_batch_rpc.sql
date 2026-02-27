-- Batched runner for historical promotion execution.
-- Uses existing per-run function and returns machine-readable progress metrics.

CREATE OR REPLACE FUNCTION public.promote_successful_journal_runs_batch(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_only_unpromoted boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_run record;
  v_processed integer := 0;
  v_success integer := 0;
  v_errors integer := 0;
  v_claims_promoted integer := 0;
  v_claims_routed integer := 0;
  v_claims_staged integer := 0;
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_limit integer := COALESCE(p_limit, 50);
  v_candidate_total integer := 0;
  v_result jsonb;
  v_error_samples jsonb := '[]'::jsonb;
BEGIN
  IF v_limit < 1 OR v_limit > 500 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 500 (got %)', v_limit;
  END IF;

  SELECT COUNT(*)
  INTO v_candidate_total
  FROM public.journal_runs jr
  WHERE jr.status = 'success'
    AND (
      NOT p_only_unpromoted
      OR NOT EXISTS (
        SELECT 1
        FROM public.promotion_log pl
        WHERE pl.run_id = jr.run_id
      )
    );

  FOR v_run IN
    SELECT jr.run_id
    FROM public.journal_runs jr
    WHERE jr.status = 'success'
      AND (
        NOT p_only_unpromoted
        OR NOT EXISTS (
          SELECT 1
          FROM public.promotion_log pl
          WHERE pl.run_id = jr.run_id
        )
      )
    ORDER BY jr.started_at NULLS LAST, jr.run_id
    OFFSET v_offset
    LIMIT v_limit
  LOOP
    BEGIN
      v_result := public.promote_journal_claims_to_belief(v_run.run_id);
      v_success := v_success + 1;
      v_claims_promoted := v_claims_promoted + COALESCE(NULLIF(v_result->>'claims_promoted', '')::integer, 0);
      v_claims_routed := v_claims_routed + COALESCE(NULLIF(v_result->>'claims_routed_to_review', '')::integer, 0);
      v_claims_staged := v_claims_staged + COALESCE(NULLIF(v_result->>'claims_staged', '')::integer, 0);
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors + 1;
        IF jsonb_array_length(v_error_samples) < 20 THEN
          v_error_samples := v_error_samples || jsonb_build_array(
            jsonb_build_object(
              'run_id', v_run.run_id,
              'error', SQLERRM
            )
          );
        END IF;
    END;

    v_processed := v_processed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'batch_limit', v_limit,
    'batch_offset', v_offset,
    'only_unpromoted', p_only_unpromoted,
    'candidate_total', v_candidate_total,
    'processed_runs', v_processed,
    'successful_runs', v_success,
    'error_runs', v_errors,
    'claims_promoted', v_claims_promoted,
    'claims_routed_to_review', v_claims_routed,
    'claims_staged', v_claims_staged,
    'remaining_runs_estimate', GREATEST(v_candidate_total - (v_offset + v_processed), 0),
    'error_samples', v_error_samples,
    'belief_claims_count', (SELECT COUNT(*) FROM public.belief_claims),
    'claim_pointers_count', (SELECT COUNT(*) FROM public.claim_pointers),
    'promotion_log_count', (SELECT COUNT(*) FROM public.promotion_log),
    'at_utc', NOW()
  );
END;
$function$;
COMMENT ON FUNCTION public.promote_successful_journal_runs_batch(integer, integer, boolean) IS
'Runs promote_journal_claims_to_belief over successful journal_runs in batches and returns aggregate progress metrics.';
REVOKE ALL ON FUNCTION public.promote_successful_journal_runs_batch(integer, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promote_successful_journal_runs_batch(integer, integer, boolean) TO service_role;
