-- Hotfix: unblock canonical belief promotion by
-- 1) accepting legacy span_bounded pointers in decide_lane + belief trigger
-- 2) making review-queue insert conflict-safe across overlapping unique indexes.

DO $do$
DECLARE
  fn text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO fn
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'decide_lane'
    AND pg_get_function_identity_arguments(p.oid) = 'claim journal_claims, context jsonb';

  IF fn IS NULL THEN
    RAISE EXCEPTION 'decide_lane function not found';
  END IF;

  fn := replace(
    fn,
    $a$if claim.pointer_type NOT IN ('transcript_span', 'document_span') then$a$,
    $b$if claim.pointer_type NOT IN ('transcript_span', 'document_span', 'span_bounded') then$b$
  );

  fn := replace(
    fn,
    $c$if claim.pointer_type = 'transcript_span' then$c$,
    $d$if claim.pointer_type IN ('transcript_span', 'span_bounded') then$d$
  );

  EXECUTE fn;
END
$do$;
DO $do$
DECLARE
  fn text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO fn
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'check_belief_promotion_pointers'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF fn IS NULL THEN
    RAISE EXCEPTION 'check_belief_promotion_pointers function not found';
  END IF;

  fn := replace(
    fn,
    $$IF source_claim.pointer_type = 'transcript_span'$$,
    $$IF source_claim.pointer_type IN ('transcript_span','span_bounded')$$
  );

  fn := replace(
    fn,
    $$RAISE EXCEPTION 'Cannot promote claim % without valid pointer (transcript_span with char positions, document_span with document FK) or review approval. pointer_type=%',$$,
    $$RAISE EXCEPTION 'Cannot promote claim % without valid pointer (transcript_span/span_bounded with char positions, document_span with document FK) or review approval. pointer_type=%',$$
  );

  EXECUTE fn;
END
$do$;
DO $do$
DECLARE
  fn text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO fn
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'promote_journal_claims_to_belief'
    AND pg_get_function_identity_arguments(p.oid) = 'p_run_id uuid';

  IF fn IS NULL THEN
    RAISE EXCEPTION 'promote_journal_claims_to_belief function not found';
  END IF;

  -- The table currently has overlapping uniqueness constraints:
  --   (call_id,item_type,item_id) and (call_id,item_type,reason)
  -- To avoid per-run aborts, use conflict-safe insertion for review rows.
  fn := regexp_replace(
    fn,
    'ON CONFLICT \\(call_id, item_type, item_id\\)\\s+DO UPDATE SET\\s+reason = EXCLUDED\\.reason,\\s+data = EXCLUDED\\.data,\\s+run_id = EXCLUDED\\.run_id,\\s+source_document_id = EXCLUDED\\.source_document_id;',
    'ON CONFLICT DO NOTHING;',
    'n'
  );

  fn := regexp_replace(
    fn,
    'ON CONFLICT \\(call_id, item_type, reason\\) WHERE call_id IS NOT NULL\\s+DO UPDATE SET\\s+data = EXCLUDED\\.data,\\s+item_id = EXCLUDED\\.item_id,\\s+run_id = EXCLUDED\\.run_id,\\s+source_document_id = EXCLUDED\\.source_document_id;',
    'ON CONFLICT DO NOTHING;',
    'n'
  );

  EXECUTE fn;
END
$do$;
