-- Migration: Create contact_fanout table (reconciliation — table already exists in prod)
-- Owner: DATA-2 (WP-3a, world-model-sprint)
-- Purpose: Maps each contact to a fanout classification (how many active projects
--          they work on) so context-assembly can use it as a tier-1 attribution signal.
-- References: attribution-accuracy-report.md §3.2 (39.5% of errors from missing contact→project)
-- Consumer: context-assembly v1.5.0, p2-eval-scorer.sh
--
-- Note: This table was created in prod prior to this migration file being committed.
-- This migration uses IF NOT EXISTS to be idempotent.

-- 1) Create the table
CREATE TABLE IF NOT EXISTS public.contact_fanout (
    contact_id              uuid NOT NULL PRIMARY KEY REFERENCES public.contacts(id),
    active_project_count    integer NOT NULL DEFAULT 0,
    affinity_project_count  integer NOT NULL DEFAULT 0,
    effective_fanout        integer NOT NULL DEFAULT 0,
    fanout_class            text NOT NULL DEFAULT 'unknown'
                            CHECK (fanout_class IN ('anchored','semi_anchored','drifter','floater','unknown')),
    fanout_computed_at      timestamptz NOT NULL DEFAULT now()
);
-- Index for joins on fanout_class (p2-eval-scorer stratification)
CREATE INDEX IF NOT EXISTS idx_contact_fanout_class
    ON public.contact_fanout (fanout_class);
-- Index for effective_fanout range queries
CREATE INDEX IF NOT EXISTS idx_contact_fanout_effective
    ON public.contact_fanout (effective_fanout);
COMMENT ON TABLE public.contact_fanout IS
    'Per-contact fanout classification derived from correspondent_project_affinity. '
    'One row per contact. Consumed by context-assembly v1.5.0 and eval scorer.';
COMMENT ON COLUMN public.contact_fanout.fanout_class IS
    'anchored=1 project, semi_anchored=2, drifter=3-4, floater=5+, unknown=no affinity data';
COMMENT ON COLUMN public.contact_fanout.effective_fanout IS
    'Max of active_project_count and affinity_project_count — the classification driver';
COMMENT ON COLUMN public.contact_fanout.active_project_count IS
    'Count of distinct active projects from interactions in the last 90 days';
COMMENT ON COLUMN public.contact_fanout.affinity_project_count IS
    'Count of distinct projects with positive weight in correspondent_project_affinity';
COMMENT ON COLUMN public.contact_fanout.fanout_computed_at IS
    'When this row was last recomputed from affinity/interaction data';
-- 2) Populate from correspondent_project_affinity + interactions (idempotent upsert)
-- Classification logic:
--   0 projects (or no data) → unknown
--   1 project  → anchored
--   2 projects → semi_anchored
--   3-4 projects → drifter
--   5+ projects → floater
INSERT INTO public.contact_fanout (contact_id, active_project_count, affinity_project_count, effective_fanout, fanout_class, fanout_computed_at)
SELECT
    c.id AS contact_id,
    COALESCE(act.project_count, 0) AS active_project_count,
    COALESCE(aff.project_count, 0) AS affinity_project_count,
    GREATEST(COALESCE(act.project_count, 0), COALESCE(aff.project_count, 0)) AS effective_fanout,
    CASE
        WHEN GREATEST(COALESCE(act.project_count, 0), COALESCE(aff.project_count, 0)) = 0 THEN 'unknown'
        WHEN GREATEST(COALESCE(act.project_count, 0), COALESCE(aff.project_count, 0)) = 1 THEN 'anchored'
        WHEN GREATEST(COALESCE(act.project_count, 0), COALESCE(aff.project_count, 0)) = 2 THEN 'semi_anchored'
        WHEN GREATEST(COALESCE(act.project_count, 0), COALESCE(aff.project_count, 0)) BETWEEN 3 AND 4 THEN 'drifter'
        ELSE 'floater'
    END AS fanout_class,
    now() AS fanout_computed_at
FROM public.contacts c
LEFT JOIN (
    SELECT
        i.contact_id,
        COUNT(DISTINCT i.project_id)::integer AS project_count
    FROM public.interactions i
    WHERE i.project_id IS NOT NULL
      AND i.event_at_utc >= (now() - interval '90 days')
    GROUP BY i.contact_id
) act ON act.contact_id = c.id
LEFT JOIN (
    SELECT
        cpa.contact_id,
        COUNT(DISTINCT cpa.project_id)::integer AS project_count
    FROM public.correspondent_project_affinity cpa
    WHERE cpa.weight > 0
    GROUP BY cpa.contact_id
) aff ON aff.contact_id = c.id
ON CONFLICT (contact_id) DO UPDATE
    SET active_project_count    = EXCLUDED.active_project_count,
        affinity_project_count  = EXCLUDED.affinity_project_count,
        effective_fanout        = EXCLUDED.effective_fanout,
        fanout_class            = EXCLUDED.fanout_class,
        fanout_computed_at      = EXCLUDED.fanout_computed_at;
