-- Migration: fix_deprecated_project_id_views
-- Date: 2026-02-19
-- Author: DEV (dev-cc session)
--
-- Purpose: Fix schema affordance for browser agents.
--   Browser agents consistently reach for the wrong tables (calls_raw, interactions)
--   because the most discoverable tables have deprecated/null columns. The v4 schema's
--   intelligence lives in spans → attributions → claims → journal, but nothing
--   signals "start here."
--
-- Changes:
--   1. CREATE v_call_ledger — flat "start here" view joining full v4 chain
--   2. REPLACE v_morning_manifest — fix broken CTEs that used interactions.project_id
--   3. REPLACE v_interactions_routing — use span-level attribution for project_id
--   4. REPLACE v_interaction_primary_project — drop deprecated columns
--
-- Risk: Read-only (views only). No table modifications. No data migration.
-- Backward compat: v_interaction_primary_project drops interaction_project_id and
--   primary_project_source columns. No Edge Functions or RPCs reference these.

-- ============================================================
-- 1. v_call_ledger — the "start here" view for browser agents
-- ============================================================
-- One row per call. Joins calls_raw → spans → attributions → projects → contacts.
-- Uses the primary span attribution (highest confidence with a non-null project).
-- Excludes shadow rows by default.

CREATE OR REPLACE VIEW v_call_ledger AS
SELECT
  cr.interaction_id,
  sa_primary.span_id,
  cr.event_at_utc                            AS call_date,
  cr.direction                               AS call_direction,
  i.contact_name,
  cr.other_party_phone                       AS contact_phone,
  i.contact_id,
  c.contact_type,
  c.trade                                    AS contact_trade,
  COALESCE(c.floats_between_projects, false) AS is_floater,
  p.name                                     AS project_name,
  cpp.project_id,
  sa_primary.decision                        AS attribution_decision,
  sa_primary.confidence                      AS attribution_confidence,
  sa_primary.attribution_lock                AS attribution_source,
  COALESCE(span_counts.span_count, 0)        AS span_count,
  i.human_summary,
  i.transcript_chars,
  i.has_scheduler_items,
  cr.is_shadow,
  cr.ingested_at_utc                         AS ingested_at
FROM calls_raw cr
LEFT JOIN interactions i
  ON i.interaction_id = cr.interaction_id
LEFT JOIN contacts c
  ON c.id = i.contact_id
LEFT JOIN v_call_primary_project cpp
  ON cpp.interaction_id = cr.interaction_id
LEFT JOIN LATERAL (
  SELECT cs2.id AS span_id, sa2.decision, sa2.confidence, sa2.attribution_lock
  FROM conversation_spans cs2
  JOIN span_attributions sa2 ON sa2.span_id = cs2.id
  WHERE cs2.interaction_id = cr.interaction_id
    AND sa2.applied_project_id IS NOT NULL
  ORDER BY sa2.confidence DESC NULLS LAST
  LIMIT 1
) sa_primary ON true
LEFT JOIN projects p
  ON p.id = cpp.project_id
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS span_count
  FROM conversation_spans cs
  WHERE cs.interaction_id = cr.interaction_id
    AND cs.is_superseded IS NOT TRUE
) span_counts ON true
WHERE cr.is_shadow IS NOT TRUE;

COMMENT ON VIEW v_call_ledger IS
  'Flat, one-row-per-call view joining calls_raw → spans → attributions → projects → contacts. '
  'Start here for call-level queries. Excludes shadow rows by default. '
  'project_name and project_id come from span_attributions (v4 SSOT), not interactions.project_id (deprecated).';


-- ============================================================
-- 2. v_morning_manifest — fix broken CTEs
-- ============================================================
-- Problem: call_counts, journal_counts, strike_counts, and review_counts all
-- grouped by interactions.project_id which is null for all v4 calls.
-- Fix: Join through v_call_primary_project to get project_id from span_attributions.

CREATE OR REPLACE VIEW v_morning_manifest AS
WITH call_counts AS (
  SELECT
    cpp.project_id,
    count(*) AS new_calls,
    count(DISTINCT i.contact_name) AS unique_contacts
  FROM interactions i
  JOIN v_call_primary_project cpp ON cpp.interaction_id = i.interaction_id
  WHERE i.event_at_utc > (now() - '24:00:00'::interval)
  GROUP BY cpp.project_id
), claim_counts AS (
  SELECT
    belief_claims.project_id,
    count(*) AS new_claims,
    count(*) FILTER (WHERE belief_claims.epistemic_status = 'decided') AS decided,
    count(*) FILTER (WHERE belief_claims.epistemic_status = 'promised') AS promised,
    count(*) FILTER (WHERE belief_claims.epistemic_status = 'observed') AS observed,
    count(*) FILTER (WHERE belief_claims.epistemic_status = 'inferred') AS inferred,
    count(*) FILTER (WHERE belief_claims.epistemic_status = 'reported') AS reported
  FROM belief_claims
  WHERE belief_claims.created_at > (now() - '24:00:00'::interval)
  GROUP BY belief_claims.project_id
), strike_counts AS (
  SELECT
    cpp.project_id,
    count(*) AS new_strikes,
    count(*) FILTER (WHERE ss.striking_score >= 0.7) AS high_strikes
  FROM striking_signals ss
  JOIN v_call_primary_project cpp ON cpp.interaction_id = ss.interaction_id
  WHERE ss.created_at > (now() - '24:00:00'::interval)
  GROUP BY cpp.project_id
), review_counts AS (
  SELECT
    cpp.project_id,
    count(*) FILTER (WHERE rq.status = 'pending') AS pending_reviews,
    count(*) FILTER (WHERE rq.status = 'resolved' AND rq.resolved_at > (now() - '24:00:00'::interval)) AS newly_resolved
  FROM review_queue rq
  JOIN v_call_primary_project cpp ON cpp.interaction_id = rq.interaction_id
  WHERE (rq.created_at > (now() - '24:00:00'::interval)
    OR rq.resolved_at > (now() - '24:00:00'::interval))
  GROUP BY cpp.project_id
), journal_counts AS (
  SELECT
    cpp.project_id,
    count(*) AS new_journal_entries
  FROM journal_claims jc
  JOIN v_call_primary_project cpp ON cpp.interaction_id = jc.call_id
  WHERE jc.created_at > (now() - '24:00:00'::interval)
  GROUP BY cpp.project_id
)
SELECT
  p.name AS project_name,
  p.id AS project_id,
  COALESCE(cc.new_calls, (0)::bigint) AS new_calls,
  COALESCE(cc.unique_contacts, (0)::bigint) AS unique_contacts,
  COALESCE(jc.new_journal_entries, (0)::bigint) AS new_journal_entries,
  COALESCE(bc.new_claims, (0)::bigint) AS new_belief_claims,
  COALESCE(bc.decided, (0)::bigint) AS claims_decided,
  COALESCE(bc.promised, (0)::bigint) AS claims_promised,
  COALESCE(bc.observed, (0)::bigint) AS claims_observed,
  COALESCE(bc.inferred, (0)::bigint) AS claims_inferred,
  COALESCE(bc.reported, (0)::bigint) AS claims_reported,
  COALESCE(sc.new_strikes, (0)::bigint) AS new_striking_signals,
  COALESCE(sc.high_strikes, (0)::bigint) AS high_confidence_strikes,
  COALESCE(rc.pending_reviews, (0)::bigint) AS pending_reviews,
  COALESCE(rc.newly_resolved, (0)::bigint) AS newly_resolved_reviews
FROM projects p
LEFT JOIN call_counts cc ON cc.project_id = p.id
LEFT JOIN journal_counts jc ON jc.project_id = p.id
LEFT JOIN claim_counts bc ON bc.project_id = p.id
LEFT JOIN strike_counts sc ON sc.project_id = p.id
LEFT JOIN review_counts rc ON rc.project_id = p.id
WHERE p.status = 'active'
  AND (COALESCE(cc.new_calls, (0)::bigint) > 0
    OR COALESCE(jc.new_journal_entries, (0)::bigint) > 0
    OR COALESCE(bc.new_claims, (0)::bigint) > 0
    OR COALESCE(sc.new_strikes, (0)::bigint) > 0
    OR COALESCE(rc.pending_reviews, (0)::bigint) > 0)
ORDER BY COALESCE(cc.new_calls, (0)::bigint) DESC,
  COALESCE(bc.new_claims, (0)::bigint) DESC;


-- ============================================================
-- 3. v_interactions_routing — fix deprecated project_id
-- ============================================================
-- Problem: Selected project_id directly from interactions — always null.
-- Fix: Join through v_call_primary_project for span-level attribution.

CREATE OR REPLACE VIEW v_interactions_routing AS
SELECT
  i.interaction_id,
  cpp.project_id,
  i.contact_id,
  i.event_at_utc,
  i.ingested_at_utc,
  (i.context_receipt ->> 'candidate_sources_split'::text) AS candidate_sources_split,
  (i.context_receipt -> 'router_candidate_set_project_ids'::text) AS router_candidate_set_project_ids,
  CASE
    WHEN (i.context_receipt -> 'continuity_candidate_calls'::text) IS NULL THEN NULL::text
    WHEN jsonb_typeof(i.context_receipt -> 'continuity_candidate_calls'::text) <> 'array'::text THEN NULL::text
    WHEN jsonb_array_length(i.context_receipt -> 'continuity_candidate_calls'::text) = 0 THEN 'none'::text
    WHEN jsonb_array_length(i.context_receipt -> 'continuity_candidate_calls'::text) = 1 THEN 'single'::text
    WHEN jsonb_array_length(i.context_receipt -> 'continuity_candidate_calls'::text) <= 3 THEN 'moderate'::text
    ELSE 'high'::text
  END AS continuity_tier,
  (i.context_receipt -> 'continuity_candidate_calls'::text) AS continuity_candidate_calls,
  ((i.context_receipt ->> 'floater_involved'::text))::boolean AS floater_involved,
  i.context_receipt
FROM interactions i
LEFT JOIN v_call_primary_project cpp ON cpp.interaction_id = i.interaction_id
WHERE i.context_receipt IS NOT NULL;


-- ============================================================
-- 4. v_interaction_primary_project — drop deprecated columns
-- ============================================================
-- Problem: Exposed interaction_project_id (always null) and primary_project_source
-- (misleading 'interaction' vs 'span_attribution' distinction).
-- Fix: Remove both. primary_project_id now always from span_attributions.
-- Note: CREATE OR REPLACE cannot drop columns, so DROP + CREATE is required.
-- No other views depend on v_interaction_primary_project (verified).

DROP VIEW IF EXISTS v_interaction_primary_project;
CREATE VIEW v_interaction_primary_project AS
WITH span_project_counts AS (
  SELECT
    cs.interaction_id,
    sa.project_id,
    count(*) AS span_count,
    max(sa.attributed_at) AS latest_attributed_at,
    count(*) FILTER (WHERE sa.attribution_lock = 'human'::text) AS human_locked_spans,
    count(*) FILTER (WHERE sa.attribution_lock IS DISTINCT FROM 'human'::text) AS nonhuman_spans
  FROM conversation_spans cs
  JOIN span_attributions sa ON sa.span_id = cs.id
  WHERE sa.project_id IS NOT NULL
  GROUP BY cs.interaction_id, sa.project_id
), primary_span_project AS (
  SELECT
    ranked.interaction_id,
    ranked.project_id,
    ranked.span_count,
    ranked.latest_attributed_at,
    ranked.human_locked_spans,
    ranked.nonhuman_spans
  FROM (
    SELECT
      spc.interaction_id,
      spc.project_id,
      spc.span_count,
      spc.latest_attributed_at,
      spc.human_locked_spans,
      spc.nonhuman_spans,
      row_number() OVER (PARTITION BY spc.interaction_id ORDER BY spc.span_count DESC, spc.latest_attributed_at DESC) AS rn
    FROM span_project_counts spc
  ) ranked
  WHERE ranked.rn = 1
)
SELECT
  i.interaction_id,
  psp.project_id AS primary_project_id,
  psp.project_id AS span_top_project_id,
  psp.span_count AS span_top_project_span_count,
  psp.human_locked_spans AS span_top_project_human_locked_spans,
  psp.nonhuman_spans AS span_top_project_model_spans,
  psp.latest_attributed_at AS span_top_project_last_attributed_at
FROM interactions i
LEFT JOIN primary_span_project psp ON psp.interaction_id = i.interaction_id;

COMMENT ON VIEW v_interaction_primary_project IS
  'Per-interaction primary project from span_attributions. '
  'Deprecated columns interaction_project_id and primary_project_source removed 2026-02-19.';
