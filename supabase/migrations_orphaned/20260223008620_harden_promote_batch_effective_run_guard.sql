-- Harden batch promotion runner against run_id/source_run_id mismatches
-- and add explicit silent-zero diagnostics.
--
-- Why:
-- - Consolidation wrapper runs can report claims_extracted > 0 while actual
--   journal_claim rows live on config.source_run_id.
-- - Naive run_id-only promotion checks can report false "zero promotion" risk.
-- - True silent-zero path remains: active claims exist but no promote/review/stage/skip writes.
--
-- Guard behavior:
-- - Use effective_run_id = source_run_id (when valid UUID) else run_id.
-- - p_only_unpromoted filter checks promotion_log on effective_run_id.
-- - Record diagnostics for zero-promotion runs with active claim input.
-- - Count silent-zero no-op runs as guarded failures in error_runs.

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

  v_active_claim_rows integer := 0;
  v_run_promoted integer := 0;
  v_run_routed integer := 0;
  v_run_staged integer := 0;
  v_run_skipped integer := 0;
  v_zero_promotion_runs integer := 0;
  v_silent_zero_guard_failures integer := 0;
  v_source_mapped_runs integer := 0;
  v_guard_samples jsonb := '[]'::jsonb;
BEGIN
  IF v_limit < 1 OR v_limit > 500 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 500 (got %)', v_limit;
  END IF;

  SELECT COUNT(*)
  INTO v_candidate_total
  FROM public.journal_runs jr
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN NULLIF(jr.config->>'source_run_id', '') ~* '^[0-9a-fA-F-]{36}$'
        THEN NULLIF(jr.config->>'source_run_id', '')::uuid
      ELSE NULL::uuid
    END AS source_run_id
  ) sr
  WHERE jr.status = 'success'
    AND (
      NOT p_only_unpromoted
      OR NOT EXISTS (
        SELECT 1
        FROM public.promotion_log pl
        WHERE pl.run_id = COALESCE(sr.source_run_id, jr.run_id)
      )
    );

  FOR v_run IN
    SELECT
      jr.run_id AS requested_run_id,
      COALESCE(sr.source_run_id, jr.run_id) AS effective_run_id,
      sr.source_run_id AS parsed_source_run_id,
      COALESCE(jr.config->>'mode', '(null)') AS mode
    FROM public.journal_runs jr
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN NULLIF(jr.config->>'source_run_id', '') ~* '^[0-9a-fA-F-]{36}$'
          THEN NULLIF(jr.config->>'source_run_id', '')::uuid
        ELSE NULL::uuid
      END AS source_run_id
    ) sr
    WHERE jr.status = 'success'
      AND (
        NOT p_only_unpromoted
        OR NOT EXISTS (
          SELECT 1
          FROM public.promotion_log pl
          WHERE pl.run_id = COALESCE(sr.source_run_id, jr.run_id)
        )
      )
    ORDER BY jr.started_at NULLS LAST, jr.run_id
    OFFSET v_offset
    LIMIT v_limit
  LOOP
    BEGIN
      IF v_run.requested_run_id <> v_run.effective_run_id THEN
        v_source_mapped_runs := v_source_mapped_runs + 1;
      END IF;

      v_result := public.promote_journal_claims_to_belief(v_run.effective_run_id);
      v_success := v_success + 1;

      v_run_promoted := COALESCE(NULLIF(v_result->>'claims_promoted', '')::integer, 0);
      v_run_routed := COALESCE(NULLIF(v_result->>'claims_routed_to_review', '')::integer, 0);
      v_run_staged := COALESCE(NULLIF(v_result->>'claims_staged', '')::integer, 0);
      v_run_skipped := COALESCE(NULLIF(v_result->>'claims_skipped_already_promoted', '')::integer, 0);

      v_claims_promoted := v_claims_promoted + v_run_promoted;
      v_claims_routed := v_claims_routed + v_run_routed;
      v_claims_staged := v_claims_staged + v_run_staged;

      SELECT COUNT(*)::integer
      INTO v_active_claim_rows
      FROM public.journal_claims jc
      WHERE jc.run_id = v_run.effective_run_id
        AND jc.active = true;

      IF v_active_claim_rows > 0 AND v_run_promoted = 0 THEN
        v_zero_promotion_runs := v_zero_promotion_runs + 1;

        IF jsonb_array_length(v_guard_samples) < 20 THEN
          v_guard_samples := v_guard_samples || jsonb_build_array(
            jsonb_build_object(
              'requested_run_id', v_run.requested_run_id,
              'effective_run_id', v_run.effective_run_id,
              'mode', v_run.mode,
              'source_run_id', v_run.parsed_source_run_id,
              'active_claim_rows', v_active_claim_rows,
              'claims_promoted', v_run_promoted,
              'claims_routed_to_review', v_run_routed,
              'claims_staged', v_run_staged,
              'claims_skipped_already_promoted', v_run_skipped,
              'guard',
                CASE
                  WHEN v_run_routed = 0 AND v_run_staged = 0 AND v_run_skipped = 0
                    THEN 'silent_zero_no_sink_writes'
                  WHEN v_run_routed > 0
                    THEN 'zero_promotion_review_lane'
                  WHEN v_run_staged > 0
                    THEN 'zero_promotion_stage_lane'
                  ELSE 'zero_promotion_other'
                END
            )
          );
        END IF;

        IF v_run_routed = 0 AND v_run_staged = 0 AND v_run_skipped = 0 THEN
          -- Treat true no-op silent-zero as a guarded failure.
          v_silent_zero_guard_failures := v_silent_zero_guard_failures + 1;
          v_errors := v_errors + 1;
          IF jsonb_array_length(v_error_samples) < 20 THEN
            v_error_samples := v_error_samples || jsonb_build_array(
              jsonb_build_object(
                'run_id', v_run.effective_run_id,
                'requested_run_id', v_run.requested_run_id,
                'error', 'silent_zero_no_sink_writes'
              )
            );
          END IF;
        END IF;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors + 1;
        IF jsonb_array_length(v_error_samples) < 20 THEN
          v_error_samples := v_error_samples || jsonb_build_array(
            jsonb_build_object(
              'run_id', v_run.effective_run_id,
              'requested_run_id', v_run.requested_run_id,
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
    'zero_promotion_runs', v_zero_promotion_runs,
    'silent_zero_guard_failures', v_silent_zero_guard_failures,
    'source_mapped_runs', v_source_mapped_runs,
    'remaining_runs_estimate', GREATEST(v_candidate_total - (v_offset + v_processed), 0),
    'guard_samples', v_guard_samples,
    'error_samples', v_error_samples,
    'belief_claims_count', (SELECT COUNT(*) FROM public.belief_claims),
    'claim_pointers_count', (SELECT COUNT(*) FROM public.claim_pointers),
    'promotion_log_count', (SELECT COUNT(*) FROM public.promotion_log),
    'at_utc', NOW()
  );
END;
$function$;

COMMENT ON FUNCTION public.promote_successful_journal_runs_batch(integer, integer, boolean) IS
'Runs promote_journal_claims_to_belief over successful journal_runs with effective source_run_id mapping, returns aggregate progress metrics, and emits silent-zero guard diagnostics.';

