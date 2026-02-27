CREATE OR REPLACE FUNCTION public.derive_affinity_weights(
  p_contact_id uuid DEFAULT NULL,
  p_human_boost integer DEFAULT 10,
  p_rejection_penalty integer DEFAULT 2,
  p_decay_rate numeric DEFAULT 0.02,
  p_apply boolean DEFAULT false
)
RETURNS TABLE (
  contact_id uuid,
  project_id uuid,
  contact_name text,
  project_name text,
  raw_signal numeric,
  days_stale numeric,
  decayed_score numeric,
  derived_weight numeric,
  current_weight numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH span_evidence AS (
    SELECT
      i.contact_id AS se_contact_id,
      sa.applied_project_id AS se_project_id,
      COUNT(*) FILTER (WHERE sa.attribution_lock = 'human') AS human_locked_spans,
      MAX(GREATEST(i.event_at_utc, sa.applied_at_utc)) AS last_span_at
    FROM span_attributions sa
    JOIN conversation_spans cs ON cs.id = sa.span_id
    JOIN interactions i ON i.interaction_id = cs.interaction_id
    WHERE cs.is_superseded = false
      AND sa.applied_project_id IS NOT NULL
      AND i.contact_id IS NOT NULL
      AND (p_contact_id IS NULL OR i.contact_id = p_contact_id)
    GROUP BY i.contact_id, sa.applied_project_id
  ),
  raw_scores AS (
    SELECT
      cpa.contact_id AS rs_contact_id,
      cpa.project_id AS rs_project_id,
      c.name AS rs_contact_name,
      p.name AS rs_project_name,
      cpa.weight AS rs_current_weight,
      GREATEST(
        cpa.confirmation_count
        + (p_human_boost * COALESCE(se.human_locked_spans, 0))
        - (p_rejection_penalty * cpa.rejection_count),
        0
      )::numeric AS rs_raw_signal,
      (EXTRACT(EPOCH FROM (NOW() - COALESCE(
        GREATEST(cpa.last_interaction_at, se.last_span_at),
        cpa.last_interaction_at,
        se.last_span_at,
        cpa.created_at
      ))) / 86400.0)::numeric AS rs_days_stale
    FROM correspondent_project_affinity cpa
    LEFT JOIN contacts c ON c.id = cpa.contact_id
    LEFT JOIN projects p ON p.id = cpa.project_id
    LEFT JOIN span_evidence se
      ON se.se_contact_id = cpa.contact_id
      AND se.se_project_id = cpa.project_id
    WHERE p_contact_id IS NULL OR cpa.contact_id = p_contact_id
  ),
  decayed AS (
    SELECT
      rs.*,
      (rs.rs_raw_signal * EXP(-1.0 * p_decay_rate * rs.rs_days_stale))::numeric AS ds_decayed
    FROM raw_scores rs
  ),
  normalized AS (
    SELECT
      d.rs_contact_id,
      d.rs_project_id,
      d.rs_contact_name,
      d.rs_project_name,
      d.rs_raw_signal,
      d.rs_days_stale,
      d.ds_decayed,
      CASE
        WHEN SUM(d.ds_decayed) OVER (PARTITION BY d.rs_contact_id) > 0
        THEN d.ds_decayed / SUM(d.ds_decayed) OVER (PARTITION BY d.rs_contact_id)
        ELSE 0
      END AS n_derived_weight,
      d.rs_current_weight
    FROM decayed d
  )
  SELECT
    n.rs_contact_id,
    n.rs_project_id,
    n.rs_contact_name,
    n.rs_project_name,
    ROUND(n.rs_raw_signal, 4),
    ROUND(n.rs_days_stale, 1),
    ROUND(n.ds_decayed, 4),
    ROUND(n.n_derived_weight, 6),
    ROUND(n.rs_current_weight, 6)
  FROM normalized n
  ORDER BY n.rs_contact_id, n.n_derived_weight DESC;

  IF p_apply THEN
    UPDATE correspondent_project_affinity cpa
    SET weight = sub.new_weight,
        updated_at = NOW()
    FROM (
      WITH se AS (
        SELECT
          i.contact_id AS se_cid,
          sa.applied_project_id AS se_pid,
          COUNT(*) FILTER (WHERE sa.attribution_lock = 'human') AS hl,
          MAX(GREATEST(i.event_at_utc, sa.applied_at_utc)) AS ls
        FROM span_attributions sa
        JOIN conversation_spans cs ON cs.id = sa.span_id
        JOIN interactions i ON i.interaction_id = cs.interaction_id
        WHERE cs.is_superseded = false
          AND sa.applied_project_id IS NOT NULL
          AND i.contact_id IS NOT NULL
          AND (p_contact_id IS NULL OR i.contact_id = p_contact_id)
        GROUP BY i.contact_id, sa.applied_project_id
      ),
      scores AS (
        SELECT
          cpa2.contact_id AS s_cid,
          cpa2.project_id AS s_pid,
          GREATEST(
            cpa2.confirmation_count
            + (p_human_boost * COALESCE(se.hl, 0))
            - (p_rejection_penalty * cpa2.rejection_count),
            0
          )::numeric
          * EXP(-1.0 * p_decay_rate * (EXTRACT(EPOCH FROM (NOW() - COALESCE(
            GREATEST(cpa2.last_interaction_at, se.ls),
            cpa2.last_interaction_at, se.ls, cpa2.created_at
          ))) / 86400.0))::numeric AS ds
        FROM correspondent_project_affinity cpa2
        LEFT JOIN se ON se.se_cid = cpa2.contact_id AND se.se_pid = cpa2.project_id
        WHERE p_contact_id IS NULL OR cpa2.contact_id = p_contact_id
      )
      SELECT s_cid, s_pid,
        CASE
          WHEN SUM(ds) OVER (PARTITION BY s_cid) > 0
          THEN ROUND(ds / SUM(ds) OVER (PARTITION BY s_cid), 6)
          ELSE 0
        END AS new_weight
      FROM scores
    ) sub
    WHERE cpa.contact_id = sub.s_cid
      AND cpa.project_id = sub.s_pid
      AND (p_contact_id IS NULL OR cpa.contact_id = p_contact_id);
  END IF;
END;
$function$;;
