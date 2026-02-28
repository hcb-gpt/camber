-- Safety scoreboard RPC for interaction-level metrics
-- Per STRAT TURN:65 taskpack=v4_safety_db_invariants

CREATE OR REPLACE FUNCTION get_safety_scoreboard(p_interaction_id text)
RETURNS TABLE (
  interaction_id text,
  spans_total bigint,
  spans_active bigint,
  attribution_count bigint,
  auto_attributed bigint,
  review_pending bigint,
  human_locked bigint,
  pct_auto_attributed numeric,
  has_evidence_receipts boolean
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p_interaction_id as interaction_id,
    (SELECT count(*) FROM conversation_spans cs WHERE cs.interaction_id = p_interaction_id)::bigint as spans_total,
    (SELECT count(*) FROM conversation_spans cs WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false)::bigint as spans_active,
    (SELECT count(*) FROM span_attributions sa 
     JOIN conversation_spans cs ON cs.id = sa.span_id 
     WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false)::bigint as attribution_count,
    (SELECT count(*) FROM span_attributions sa 
     JOIN conversation_spans cs ON cs.id = sa.span_id 
     WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false AND sa.decision = 'assign')::bigint as auto_attributed,
    (SELECT count(*) FROM review_queue rq 
     JOIN conversation_spans cs ON cs.id = rq.span_id 
     WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false AND rq.status = 'pending')::bigint as review_pending,
    (SELECT count(*) FROM span_attributions sa 
     JOIN conversation_spans cs ON cs.id = sa.span_id 
     WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false AND sa.attribution_lock = 'human')::bigint as human_locked,
    -- Percentage auto-attributed (NULL if no spans)
    CASE 
      WHEN (SELECT count(*) FROM conversation_spans cs WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false) = 0 
      THEN NULL
      ELSE ROUND(
        (SELECT count(*) FROM span_attributions sa 
         JOIN conversation_spans cs ON cs.id = sa.span_id 
         WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false AND sa.decision = 'assign')::numeric /
        NULLIF((SELECT count(*) FROM conversation_spans cs WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false), 0) * 100, 1
      )
    END as pct_auto_attributed,
    -- Check if attributions have evidence (anchors array not empty)
    (SELECT bool_and(jsonb_array_length(COALESCE(sa.anchors, '[]'::jsonb)) > 0)
     FROM span_attributions sa 
     JOIN conversation_spans cs ON cs.id = sa.span_id 
     WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false AND sa.decision = 'assign') as has_evidence_receipts;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_safety_scoreboard(text) IS
  'Returns safety metrics for an interaction: span counts, attribution rates, human locks, evidence presence';;
