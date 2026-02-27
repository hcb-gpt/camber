-- Disable the trigger that re-resolves speaker_contact_id on UPDATE
ALTER TABLE journal_claims DISABLE TRIGGER trg_resolve_journal_claim_speakers;

-- Clear wrong Zack speaker_contact_id values
-- These are claims on other people's interactions where Zack was incorrectly resolved as speaker
UPDATE journal_claims jc
SET speaker_contact_id = NULL
FROM interactions i
WHERE i.interaction_id = jc.call_id
  AND jc.speaker_contact_id IN (SELECT id FROM contacts WHERE name ILIKE '%sittler%')
  AND i.contact_id IS NOT NULL
  AND i.contact_id NOT IN (SELECT id FROM contacts WHERE name ILIKE '%sittler%');

-- Re-enable the trigger
ALTER TABLE journal_claims ENABLE TRIGGER trg_resolve_journal_claim_speakers;;
