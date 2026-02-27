-- Migration: Prune over-broad project_contacts rows that poison attribution
-- Owner: DATA-2 (WP-3a data quality fix, world-model-sprint)
-- Date: 2026-02-16
--
-- Problem: 119 rows with source='data_inferred' mapped 10 subcontractors to ALL 12 projects.
-- This defeated context-assembly SOURCE 1 (project_contacts lookup) by spraying 12 equal-weight
-- candidates (0.22 each) instead of discriminating by real association.
-- Example: Brian Dove mapped to 12 projects when GT says Woodbery framing only.
--
-- Additionally, 8 null-source rows for Dwayne Brown had the same spray pattern.
--
-- Fix: Delete these fabricated spray rows. Real signal lives in:
--   - correspondent_project_affinity (SOURCE 2, interaction-weighted)
--   - v_contact_project_affinity view (call-count based affinity percentages)
--   - Remaining project_contacts rows with evidence-backed sources
--
-- Impact: 127 rows deleted. Remaining project_contacts: 135 rows with evidence-backed sources.
-- After cleanup, contact_fanout refreshed to reflect accurate fanout classifications.
--
-- Affected contacts (data_inferred, 10 contacts x ~12 projects each):
--   Zach Givens, Brandon Hightower, Brian Dove, Eric Atkinson, Flynt Treadaway,
--   Gatlin Hawkins, Malcolm Hetzer, Randy Booth, Taylor Shannon, Anthony Cottrell
--
-- Affected contacts (null source, 1 contact x 8 projects):
--   Dwayne Brown (retained: 1 gmail_research row for Skelton Residence = correct GT)

-- Step 1: Delete data_inferred spray rows
DELETE FROM public.project_contacts WHERE source = 'data_inferred';
-- Step 2: Delete null-source spray rows
DELETE FROM public.project_contacts WHERE source IS NULL;
-- Step 3: Refresh contact_fanout from interaction + affinity data
WITH refreshed AS (
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
        END AS fanout_class
    FROM public.contacts c
    LEFT JOIN (
        SELECT i.contact_id, COUNT(DISTINCT i.project_id)::integer AS project_count
        FROM public.interactions i
        WHERE i.project_id IS NOT NULL AND i.event_at_utc >= (now() - interval '90 days')
        GROUP BY i.contact_id
    ) act ON act.contact_id = c.id
    LEFT JOIN (
        SELECT cpa.contact_id, COUNT(DISTINCT cpa.project_id)::integer AS project_count
        FROM public.correspondent_project_affinity cpa
        WHERE cpa.weight > 0
        GROUP BY cpa.contact_id
    ) aff ON aff.contact_id = c.id
)
UPDATE public.contact_fanout cf
SET
    active_project_count = r.active_project_count,
    affinity_project_count = r.affinity_project_count,
    effective_fanout = r.effective_fanout,
    fanout_class = r.fanout_class,
    fanout_computed_at = now()
FROM refreshed r
WHERE cf.contact_id = r.contact_id
  AND (cf.active_project_count != r.active_project_count
    OR cf.affinity_project_count != r.affinity_project_count
    OR cf.effective_fanout != r.effective_fanout
    OR cf.fanout_class != r.fanout_class);
