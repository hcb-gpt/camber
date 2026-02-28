UPDATE journal_claims jc
SET speaker_contact_id = NULL
FROM interactions i
WHERE i.interaction_id = jc.call_id
  AND jc.speaker_contact_id IN (SELECT id FROM contacts WHERE name ILIKE '%sittler%')
  AND i.contact_id IS NOT NULL
  AND i.contact_id NOT IN (SELECT id FROM contacts WHERE name ILIKE '%sittler%');;
