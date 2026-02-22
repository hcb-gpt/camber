-- open_loop_silence_candidates.sql
-- Purpose:
--   Identify likely "silence" failures where a commitment/deadline claim is older
--   than 48h and there has been no follow-up call from the same contact.
--
-- Usage:
--   ./scripts/query.sh --file scripts/open_loop_silence_candidates.sql
--
-- Notes:
--   - Read-only query (SELECT/WITH only).
--   - This is a candidate list, not a final adjudication.

WITH deadline_claims AS (
  SELECT
    jc.claim_id,
    jc.call_id,
    COALESCE(jc.claim_project_id_norm, jc.claim_project_id, jc.project_id) AS project_id,
    jc.claim_type,
    jc.claim_text,
    jc.created_at AS claim_created_at,
    i.contact_phone,
    i.contact_name,
    i.event_at_utc AS call_event_at
  FROM public.journal_claims jc
  JOIN public.interactions i
    ON i.interaction_id = jc.call_id
  WHERE jc.active IS TRUE
    AND jc.claim_type = 'deadline'
    AND COALESCE(i.is_shadow, FALSE) = FALSE
),
open_loop_context AS (
  SELECT
    dc.*,
    jol1.id AS open_loop_id,
    jol1.status AS open_loop_status,
    jol1.created_at AS open_loop_created_at,
    jol1.description AS open_loop_description
  FROM deadline_claims dc
  LEFT JOIN LATERAL (
    SELECT
      jol.id,
      jol.status,
      jol.created_at,
      jol.description
    FROM public.journal_open_loops jol
    WHERE jol.call_id = dc.call_id
      AND (jol.project_id = dc.project_id OR jol.project_id IS NULL)
      AND jol.status = 'open'
    ORDER BY jol.created_at DESC
    LIMIT 1
  ) jol1 ON TRUE
),
follow_up_after_claim AS (
  SELECT
    olc.claim_id,
    MIN(i2.event_at_utc) AS first_follow_up_at,
    COUNT(*) AS follow_up_calls
  FROM open_loop_context olc
  JOIN public.interactions i2
    ON i2.contact_phone = olc.contact_phone
   AND COALESCE(i2.is_shadow, FALSE) = FALSE
   AND i2.event_at_utc > olc.claim_created_at
  GROUP BY olc.claim_id
)
SELECT
  olc.claim_id,
  olc.call_id,
  olc.claim_type,
  olc.claim_created_at,
  ROUND(EXTRACT(EPOCH FROM (NOW() - olc.claim_created_at)) / 3600.0, 1) AS hours_since_claim,
  p.name AS project_name,
  olc.contact_name,
  olc.contact_phone,
  COALESCE(olc.open_loop_id::text, 'NONE') AS open_loop_id,
  olc.open_loop_description,
  LEFT(olc.claim_text, 180) AS claim_text_excerpt,
  COALESCE(fu.follow_up_calls, 0) AS follow_up_calls,
  fu.first_follow_up_at
FROM open_loop_context olc
LEFT JOIN follow_up_after_claim fu
  ON fu.claim_id = olc.claim_id
LEFT JOIN public.projects p
  ON p.id = olc.project_id
WHERE olc.claim_created_at < NOW() - INTERVAL '48 hours'
  AND COALESCE(fu.follow_up_calls, 0) = 0
ORDER BY olc.claim_created_at ASC
LIMIT 50;
