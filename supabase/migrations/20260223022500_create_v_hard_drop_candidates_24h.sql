-- Hard-drop SLA monitor v1
-- Finds calls that entered pipeline but never got fully attributed
-- Excludes: SMS (not in pipeline scope), shadow calls, calls < 30 min old (processing window)

CREATE OR REPLACE VIEW public.v_hard_drop_candidates_24h AS
SELECT
  cr.interaction_id,
  cr.ingested_at_utc,
  cr.channel,
  cr.pipeline_version,
  length(cr.transcript) AS transcript_len,
  CASE
    WHEN cs_count.span_count IS NULL OR cs_count.span_count = 0 THEN 'no_spans'
    WHEN sa_count.attrib_count IS NULL OR sa_count.attrib_count = 0
      THEN 'no_attributions'
    WHEN sa_count.attrib_count < cs_count.span_count
      THEN 'partial_attributions'
    ELSE 'unknown'
  END AS drop_type,
  COALESCE(cs_count.span_count, 0) AS span_count,
  COALESCE(sa_count.attrib_count, 0) AS attribution_count
FROM calls_raw cr
  LEFT JOIN LATERAL (
    SELECT count(*) AS span_count
    FROM conversation_spans cs
    WHERE cs.interaction_id = cr.interaction_id
  ) cs_count ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS attrib_count
    FROM span_attributions sa
      JOIN conversation_spans cs2 ON cs2.id = sa.span_id
    WHERE cs2.interaction_id = cr.interaction_id
  ) sa_count ON true
WHERE cr.ingested_at_utc > now() - interval '24 hours'
  AND cr.ingested_at_utc < now() - interval '30 minutes'
  AND cr.channel = 'call'
  AND cr.is_shadow IS NOT TRUE
  AND (
    cs_count.span_count IS NULL OR cs_count.span_count = 0
    OR sa_count.attrib_count IS NULL
    OR sa_count.attrib_count < cs_count.span_count
  );

COMMENT ON VIEW public.v_hard_drop_candidates_24h IS
  'Hard-drop SLA monitor: calls with missing spans or attributions in last 24h';
