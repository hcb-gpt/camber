-- PR-11: Filter blocked/internal projects from geo queries
-- STRAT directive: exclude blocked/inactive/closed projects from enroute detection
-- Only include: active, warranty, estimating AND project_kind='client'
-- STRAT TURN14: Added project_kind filter to exclude internal/owner projects

BEGIN;
-- ============================================================
-- 1. UPDATE v_span_enroute VIEW
-- Add project status filter to nearest project calculation
-- ============================================================
CREATE OR REPLACE VIEW v_span_enroute AS
WITH origin AS (
  SELECT DISTINCT ON (spm.span_id)
    spm.span_id,
    spm.place_id,
    spm.verb_hint,
    spm.confidence
  FROM span_place_mentions spm
  WHERE spm.role = 'origin'
  ORDER BY spm.span_id, spm.confidence DESC NULLS LAST, spm.created_at DESC
),
dest AS (
  SELECT DISTINCT ON (spm.span_id)
    spm.span_id,
    spm.place_id,
    spm.verb_hint,
    spm.confidence
  FROM span_place_mentions spm
  WHERE spm.role = 'destination'
  ORDER BY spm.span_id, spm.confidence DESC NULLS LAST, spm.created_at DESC
),
dg AS (
  SELECT
    d.span_id,
    gp.id AS dest_place_id,
    gp.name AS dest_place_name,
    gp.lat,
    gp.lon,
    d.verb_hint
  FROM dest d
  JOIN geo_places gp ON gp.id = d.place_id
),
np AS (
  SELECT
    dg.span_id,
    pg.project_id,
    haversine_miles(dg.lat, dg.lon, pg.lat, pg.lon) AS distance_mi,
    ROW_NUMBER() OVER (PARTITION BY dg.span_id ORDER BY haversine_miles(dg.lat, dg.lon, pg.lat, pg.lon)) AS rn
  FROM dg
  JOIN project_geo pg ON TRUE
  -- PR-11: Filter to only active/warranty/estimating client projects
  JOIN projects p ON p.id = pg.project_id
    AND p.status IN ('active', 'warranty', 'estimating')
    AND p.project_kind = 'client'
)
SELECT
  COALESCE(dg.span_id, o.span_id) AS span_id,
  o.place_id AS origin_place_id,
  gpo.name AS origin_place_name,
  dg.dest_place_id AS destination_place_id,
  dg.dest_place_name AS destination_place_name,
  dg.verb_hint AS destination_verb_hint,
  CASE WHEN dg.verb_hint IS NULL THEN 'weak' ELSE 'explicit' END AS enroute_confidence,
  np.project_id AS nearest_project_to_destination_id,
  np.distance_mi AS nearest_project_to_destination_distance_mi
FROM origin o
FULL JOIN dg ON dg.span_id = o.span_id
LEFT JOIN geo_places gpo ON gpo.id = o.place_id
LEFT JOIN np ON np.span_id = COALESCE(dg.span_id, o.span_id) AND np.rn = 1;
COMMENT ON VIEW v_span_enroute IS
  'Enroute detection view for spans with origin/destination mentions. PR-11: Filters to active/warranty/estimating client projects only.';
COMMIT;
