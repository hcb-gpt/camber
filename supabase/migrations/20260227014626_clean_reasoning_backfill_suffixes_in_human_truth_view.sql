
-- Replace v_human_truth_attributions view to strip backfill audit suffixes from reasoning
-- Raw reasoning remains accessible via span_attributions.reasoning
-- Strips: bracket annotations, pipe-delimited chains, inline gate/stopline/safe tags, BizDev gate suffix
CREATE OR REPLACE VIEW v_human_truth_attributions AS
SELECT sa.id AS attribution_id,
    sa.span_id,
    cs.interaction_id,
    i.id AS interaction_uuid,
    cs.span_index,
    i.event_at_utc,
    sa.applied_at_utc AS resolved_at_attribution,
    rq.resolved_at AS resolved_at_review,
    i.contact_id,
    i.contact_name,
    COALESCE(c.phone, i.contact_phone) AS contact_phone,
    cs.transcript_segment,
    sa.applied_project_id AS chosen_project_id,
    p.name AS chosen_project_name,
    CASE
        WHEN sa.applied_project_id IS NOT NULL THEN 'PROJECT'::text
        WHEN rq.resolution_action = ANY (ARRAY['unknown'::text, 'no_project'::text]) THEN 'UNKNOWN'::text
        WHEN rq.resolution_action = 'needs_split'::text THEN 'NEEDS_SPLIT'::text
        ELSE 'UNKNOWN'::text
    END AS label_type,
    rq.id AS review_queue_id,
    rq.resolved_by AS reviewer_id,
    rq.resolution_action,
    rq.resolution_notes,
    ol.id AS override_log_id,
    ol.idempotency_key,
    ol.reason AS override_reason,
    sa.project_id AS ai_suggested_project_id,
    sa.decision AS ai_decision,
    sa.confidence AS ai_confidence,
    sa.model_id,
    sa.prompt_version,
    -- Cleaned reasoning: strips all backfill audit suffixes
    BTRIM(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  sa.reasoning,
                  E'\\s*\\|\\s*fail_closed:.*$', '', 'n'
                ),
                E'\\s*\\[[A-Z_]*BACKFILL[^\\]]*\\]', '', 'g'
              ),
              E'\\s*BizDev prospect gate held project assignment\\s*\\([^)]*\\)\\.?', '', 'g'
            ),
            E'\\s*deterministic_[a-z_]+_gate:\\s*forced assign to homeowner project [0-9a-f-]+\\s*\\([^)]*\\)\\.?', '', 'g'
          ),
          E'\\s*stopline_[a-z_]+:[a-z_]+\\.?', '', 'g'
        ),
        E'\\s*safe_[a-z_]+:\\s*safe_[a-z_]+\\.?', '', 'g'
      )
    ) AS reasoning,
    sa.anchors,
    sa.candidates_snapshot,
    sa.top_candidates,
    CASE
        WHEN sa.applied_project_id IS NOT NULL AND sa.project_id IS NOT NULL AND sa.applied_project_id <> sa.project_id THEN true
        ELSE false
    END AS is_correction,
    (((('x'::text || "left"(md5(sa.span_id::text), 8)))::bit(32)::integer % 20) = 0) AS is_holdout,
    sa.attribution_lock,
    sa.attribution_source,
    i.channel
FROM span_attributions sa
    JOIN conversation_spans cs ON cs.id = sa.span_id
    JOIN interactions i ON i.interaction_id = cs.interaction_id
    LEFT JOIN contacts c ON c.id = i.contact_id
    LEFT JOIN projects p ON p.id = sa.applied_project_id
    LEFT JOIN review_queue rq ON rq.span_id = sa.span_id
    LEFT JOIN override_log ol ON ol.review_queue_id = rq.id AND ol.idempotency_key ~~ 'resolve:%'::text
WHERE sa.attribution_lock = 'human'::text
    AND cs.is_superseded = false
    AND (COALESCE(sa.model_id, ''::text) <> ALL (ARRAY['audit_hard_drop_backfill'::text, 'data4.manual.test_fixture'::text]));
;
