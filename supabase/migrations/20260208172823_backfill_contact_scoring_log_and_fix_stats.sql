
-- Step 1: Backfill scoring log from existing interactions
INSERT INTO contact_scoring_log (contact_id, interaction_id, transcript_chars, scored_at)
SELECT 
  i.contact_id,
  i.interaction_id,
  COALESCE(i.transcript_chars, 0),
  COALESCE(i.ingested_at_utc, now())
FROM interactions i
WHERE i.contact_id IS NOT NULL
ON CONFLICT (contact_id, interaction_id) DO NOTHING;

-- Step 2: Recalculate correct stats from actual data
WITH correct_stats AS (
  SELECT 
    i.contact_id,
    count(DISTINCT i.interaction_id) as correct_interaction_count,
    max(i.event_at_utc) as correct_last_interaction,
    sum(COALESCE(i.transcript_chars, 0)) as correct_transcript_chars
  FROM interactions i
  WHERE i.contact_id IS NOT NULL
  GROUP BY i.contact_id
)
UPDATE contacts c SET
  interaction_count = cs.correct_interaction_count,
  last_interaction_at = cs.correct_last_interaction,
  total_transcript_chars = cs.correct_transcript_chars,
  updated_at = now()
FROM correct_stats cs
WHERE c.id = cs.contact_id
  AND (c.interaction_count != cs.correct_interaction_count
    OR c.total_transcript_chars != cs.correct_transcript_chars);

-- Step 3: Zero out contacts with no interactions (orphaned stats)
UPDATE contacts SET
  interaction_count = 0,
  total_transcript_chars = 0,
  updated_at = now()
WHERE interaction_count > 0
  AND id NOT IN (SELECT DISTINCT contact_id FROM interactions WHERE contact_id IS NOT NULL);
;
