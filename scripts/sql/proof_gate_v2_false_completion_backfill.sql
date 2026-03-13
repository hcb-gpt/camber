-- DRAFT ONLY.
--
-- Purpose:
--   Identify and retro-flag the exact swarm completions that closed with
--   `PROOF: file_written ...` only while ratifying CAMBER attribution work.
--
-- Safety:
--   Do not apply until the proof-gate v2 trigger migration has peer review.

WITH target_receipts AS (
  SELECT unnest(
    ARRAY[
      'completion__handoff__vp__dev__camber_attribution_wave1_model_error_commit__20260312__20260312T214103Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_a__20260312__20260312T221006Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_b__20260312__20260312T221007Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_c__20260312__20260312T221008Z',
      'completion__directive__ceo__vp__authorize_swarm_proof_wave__20260312__20260312T221114Z',
      'completion__handoff__vp__ceo__swarm_launcher_direction__20260312T2146Z__20260312T221134Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_01__20260312__20260312T230039Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_02__20260312__20260312T230044Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_03__20260312__20260312T230042Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_04__20260312__20260312T233621Z'
    ]::text[]
  ) AS receipt
)
SELECT
  t.receipt,
  t.created_at,
  t.proof_compliant,
  t.governance_hold,
  t.resolution,
  t.proof,
  t.governance_flags
FROM public.tram_messages t
JOIN target_receipts r ON r.receipt = t.receipt
ORDER BY t.created_at;

/*
WITH target_receipts AS (
  SELECT unnest(
    ARRAY[
      'completion__handoff__vp__dev__camber_attribution_wave1_model_error_commit__20260312__20260312T214103Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_a__20260312__20260312T221006Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_b__20260312__20260312T221007Z',
      'completion__handoff__vp__dev__camber_attr_proof_wave_batch_c__20260312__20260312T221008Z',
      'completion__directive__ceo__vp__authorize_swarm_proof_wave__20260312__20260312T221114Z',
      'completion__handoff__vp__ceo__swarm_launcher_direction__20260312T2146Z__20260312T221134Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_01__20260312__20260312T230039Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_02__20260312__20260312T230044Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_03__20260312__20260312T230042Z',
      'completion__handoff__vp__dev__camber_attr_scale10_batch_04__20260312__20260312T233621Z'
    ]::text[]
  ) AS receipt
)
UPDATE public.tram_messages t
SET
  proof_compliant = false,
  governance_hold = true,
  governance_flags = COALESCE(t.governance_flags, '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object(
      'rule', 'PROOF_GATE_V2_RETROACTIVE',
      'violation', 'CAMBER attribution swarm completion closed with file_written-only proof and no DB_PROOF counts.',
      'flagged_by', 'proof_gate_v2_backfill',
      'detected_at', now()::text
    ))
WHERE t.receipt IN (SELECT receipt FROM target_receipts)
  AND NOT COALESCE(t.governance_flags, '[]'::jsonb)
    @> '[{"rule":"PROOF_GATE_V2_RETROACTIVE"}]'::jsonb;
*/
