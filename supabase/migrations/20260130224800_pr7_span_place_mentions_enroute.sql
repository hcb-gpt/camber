-- PR-7: Span Place Mentions with Enroute Role Tagging
-- Creates span_place_mentions table for storing detected place mentions with roles
--
-- POLICY (STRAT-1 BLOCK):
-- - Role tagging is VERB-DRIVEN only
-- - "destination" requires: headed to, going to, on my way to, driving to
-- - "origin" requires: coming from, leaving, back from, left from
-- - Single place mention without verb = "proximity" (no direction inferred)
-- - NEVER infer direction from a single place without explicit verb

BEGIN;
-- ============================================================
-- 1. CREATE span_place_mentions TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS span_place_mentions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  span_id UUID NOT NULL REFERENCES conversation_spans(id) ON DELETE CASCADE,

  -- Place reference (from geo_places)
  geo_place_id UUID REFERENCES geo_places(id),
  place_name TEXT NOT NULL,

  -- Coordinates (denormalized for query efficiency)
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,

  -- Role tagging (verb-driven)
  role TEXT NOT NULL CHECK (role IN ('proximity', 'origin', 'destination')),
  trigger_verb TEXT,  -- The verb that determined the role (NULL for proximity)

  -- Match context
  char_offset INT,
  snippet TEXT,  -- Context window around mention

  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE span_place_mentions IS
  'Place mentions detected in span transcripts with verb-driven role tagging. POLICY: Role is ONLY assigned via explicit verbs - never inferred from single place.';
COMMENT ON COLUMN span_place_mentions.role IS
  'proximity = no directional verb; origin = leaving/coming from; destination = headed to/going to. VERB-DRIVEN ONLY.';
COMMENT ON COLUMN span_place_mentions.trigger_verb IS
  'The directional verb that triggered role assignment (e.g., "headed to", "coming from"). NULL for proximity.';
-- ============================================================
-- 2. INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_span_place_mentions_span ON span_place_mentions(span_id);
CREATE INDEX IF NOT EXISTS idx_span_place_mentions_geo_place ON span_place_mentions(geo_place_id);
CREATE INDEX IF NOT EXISTS idx_span_place_mentions_role ON span_place_mentions(role);
-- Unique constraint: one mention per span+place+role
CREATE UNIQUE INDEX IF NOT EXISTS span_place_mentions_span_place_role_uq
  ON span_place_mentions (span_id, COALESCE(geo_place_id, '00000000-0000-0000-0000-000000000000'::uuid), role);
-- ============================================================
-- 3. RLS (service_role only for now)
-- ============================================================
ALTER TABLE span_place_mentions ENABLE ROW LEVEL SECURITY;
-- ============================================================
-- 4. VERB PATTERNS VIEW (reference for context-assembly)
-- ============================================================
-- This view documents the canonical verb patterns for role detection
-- Context-assembly uses these patterns deterministically

CREATE OR REPLACE VIEW v_enroute_verb_patterns AS
SELECT
  'destination' AS role,
  ARRAY[
    'headed to',
    'heading to',
    'going to',
    'on my way to',
    'on the way to',
    'driving to',
    'heading over to',
    'headed over to',
    'going over to',
    'en route to',
    'enroute to'
  ] AS patterns,
  'Indicates caller is traveling TOWARD a location' AS description
UNION ALL
SELECT
  'origin' AS role,
  ARRAY[
    'coming from',
    'came from',
    'leaving',
    'left from',
    'left',
    'back from',
    'returning from',
    'just left',
    'driving from',
    'on my way from'
  ] AS patterns,
  'Indicates caller is traveling AWAY FROM a location' AS description;
COMMENT ON VIEW v_enroute_verb_patterns IS
  'Canonical verb patterns for enroute role detection. POLICY: Only these verbs trigger role assignment - never infer from proximity alone.';
COMMIT;
