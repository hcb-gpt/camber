-- v2.10.0: Client attribution rule — backfill existing client spans
--
-- Rule: When a call or text is from/to a contact listed in project_clients,
-- and that contact maps to exactly ONE project, the attribution should always
-- be that project. This migration fixes existing data; the pipeline rule
-- lives in context-assembly + ai-router (client_override gate).
--
-- Part 1: Fix 4 misattributed spans (assigned to WRONG project)
-- Part 2: Promote 18 review/none spans to assign for 1:1 clients
--
-- Preconditions verified:
--   - All target interactions have evidence_events (trigger-safe)
--   - Woodbery (multi-project) spans excluded from auto-fix
--   - Human locks preserved (set to 'human' on correction)

-----------------------------------------------------------------------
-- PART 1: Fix 4 misattributed spans (wrong project assigned)
-----------------------------------------------------------------------

-- 1A: Kaylen Hurley — 3 spans wrongly assigned to Permar Residence
-- Root cause: permitting/erosion topic overlap between Hurley and Permar
UPDATE span_attributions
SET project_id         = 'ed8e85a2-c79c-4951-aee1-4e17254c06a0',  -- Hurley Residence
    applied_project_id = 'ed8e85a2-c79c-4951-aee1-4e17254c06a0',
    attribution_lock   = 'human',
    attribution_source = 'client_deterministic_override',
    needs_review       = false,
    reasoning = COALESCE(reasoning, '') || E'\n[CLIENT_RULE_BACKFILL: Contact is Kaylen Hurley (project_clients) -> Hurley Residence. Previous: Permar Residence (topic false-match on permitting).]'
WHERE span_id IN (
  '9ec9ff41-20d3-48d8-abc6-6ddc55af139a',
  '625e9940-9ac9-4bcd-8b73-cbb418a50baa',
  '33393064-b343-4b6a-9872-86f8af717187'
);

-- 1B: Shayelyn Woodbery — 1 span wrongly assigned to Moss Residence
-- Root cause: "Bishop" geo anchor false-matched to Moss geo context
UPDATE span_attributions
SET project_id         = '7db5e186-7dda-4c2c-b85e-7235b67e06d8',  -- Woodbery Residence
    applied_project_id = '7db5e186-7dda-4c2c-b85e-7235b67e06d8',
    attribution_lock   = 'human',
    attribution_source = 'client_deterministic_override',
    needs_review       = false,
    reasoning = COALESCE(reasoning, '') || E'\n[CLIENT_RULE_BACKFILL: Contact is Shayelyn Woodbery (project_clients) -> Woodbery Residence. Previous: Moss Residence (Bishop geo false-match).]'
WHERE span_id = '3c125513-2502-49f0-b095-e8074f6eb268';

-----------------------------------------------------------------------
-- PART 2: Promote review/none -> assign for 1:1 client contacts
-- (contacts with exactly one project in project_clients)
-----------------------------------------------------------------------
WITH single_project_clients AS (
  SELECT contact_id,
         (array_agg(project_id))[1] AS project_id
  FROM project_clients
  GROUP BY contact_id
  HAVING count(DISTINCT project_id) = 1
),
promotable AS (
  SELECT sa.span_id, spc.project_id AS client_project_id
  FROM single_project_clients spc
  JOIN interactions i ON i.contact_id = spc.contact_id
  JOIN conversation_spans cs ON cs.interaction_id = i.interaction_id
    AND NOT cs.is_superseded
  JOIN span_attributions sa ON sa.span_id = cs.id
  WHERE sa.decision IN ('review', 'none')
    AND (sa.attribution_lock IS NULL OR sa.attribution_lock = 'ai')
)
UPDATE span_attributions sa
SET decision           = 'assign',
    project_id         = p.client_project_id,
    applied_project_id = p.client_project_id,
    attribution_lock   = 'human',
    attribution_source = 'client_deterministic_override',
    needs_review       = false,
    confidence         = GREATEST(COALESCE(sa.confidence, 0), 0.92),
    reasoning = COALESCE(sa.reasoning, '') || E'\n[CLIENT_RULE_BACKFILL: Contact is a 1:1 project_client -> auto-assigned to their project.]'
FROM promotable p
WHERE sa.span_id = p.span_id;
