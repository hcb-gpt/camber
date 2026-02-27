-- Wave-2 non-overlap implementation slice (dev-4)
-- Additive update to v_project_feed in the open-loop lane.
-- Protected lanes intentionally untouched:
-- - morning-digest
-- - v_morning_manifest

CREATE OR REPLACE VIEW public.v_project_feed AS
SELECT
  p.id AS project_id,
  p.name AS project_name,
  p.status AS project_status,
  p.phase,
  p.client_name,
  (SELECT count(*) FROM interactions i WHERE i.project_id = p.id) AS total_interactions,
  (SELECT max(i.event_at_utc) FROM interactions i WHERE i.project_id = p.id) AS last_interaction_at,
  (SELECT count(*) FROM interactions i
   WHERE i.project_id = p.id
   AND i.event_at_utc >= now() - interval '7 days') AS interactions_7d,
  (SELECT count(*) FROM journal_claims jc
   WHERE jc.project_id = p.id
   AND jc.active = true) AS active_journal_claims,
  (SELECT count(*) FROM journal_open_loops ol
   WHERE ol.project_id = p.id
   AND ol.status = 'open') AS open_loops,
  (SELECT count(*) FROM belief_claims bc
   WHERE bc.project_id = p.id) AS promoted_claims,
  (SELECT max(bc.event_at_utc) FROM belief_claims bc
   WHERE bc.project_id = p.id) AS last_promoted_at,
  (SELECT count(*) FROM striking_signals ss
   JOIN conversation_spans cs ON ss.span_id = cs.id
   JOIN span_attributions sa ON sa.span_id = cs.id
   WHERE sa.applied_project_id = p.id) AS striking_signal_count,
  (SELECT max(ss.created_at) FROM striking_signals ss
   JOIN conversation_spans cs ON ss.span_id = cs.id
   JOIN span_attributions sa ON sa.span_id = cs.id
   WHERE sa.applied_project_id = p.id) AS last_striking_at,
  (SELECT count(*) FROM span_attributions sa
   JOIN conversation_spans cs ON sa.span_id = cs.id
   WHERE cs.interaction_id IN (
     SELECT i2.interaction_id FROM interactions i2
     WHERE i2.project_id = p.id)
   AND sa.needs_review = true) AS pending_reviews,
  CASE
    WHEN (SELECT count(*) FROM journal_open_loops ol2
          WHERE ol2.project_id = p.id AND ol2.status = 'open') >= 5
      THEN 'high_open_loops'
    WHEN (SELECT count(*) FROM striking_signals ss2
          JOIN conversation_spans cs2 ON ss2.span_id = cs2.id
          JOIN span_attributions sa2 ON sa2.span_id = cs2.id
          WHERE sa2.applied_project_id = p.id
          AND ss2.created_at >= now() - interval '7 days') >= 3
      THEN 'elevated_striking'
    WHEN (SELECT max(i3.event_at_utc) FROM interactions i3
          WHERE i3.project_id = p.id) < now() - interval '14 days'
      THEN 'stale_project'
    ELSE 'normal'
  END AS risk_flag,
  (SELECT count(*) FROM journal_open_loops ol3
   WHERE ol3.project_id = p.id
   AND ol3.status = 'open'
   AND ol3.created_at < now() - interval '48 hours') AS stale_open_loops_48h,
  (SELECT min(ol4.created_at) FROM journal_open_loops ol4
   WHERE ol4.project_id = p.id
   AND ol4.status = 'open') AS oldest_open_loop_at,
  (SELECT round((extract(epoch FROM (now() - min(ol5.created_at))) / 3600.0)::numeric, 1)
   FROM journal_open_loops ol5
   WHERE ol5.project_id = p.id
   AND ol5.status = 'open') AS oldest_open_loop_age_hours
FROM projects p
ORDER BY last_interaction_at DESC NULLS LAST;
