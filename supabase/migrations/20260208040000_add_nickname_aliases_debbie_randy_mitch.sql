-- Add missing nickname aliases identified during 100-pair eval
-- Receipt: eval_pairs_supplement_100_pair_complete
-- Gaps found: Debbie→Deborah, Randy→Randall, Mitch→Mitchell
--
-- These are contact-level alias additions. If the contact already has aliases,
-- we append; if not, we initialize the array.

-- Debbie → add "Deborah" variant if a contact named Debbie exists without it
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Deborah'
)
WHERE LOWER(name) LIKE '%debbie%'
  AND NOT ('Deborah' = ANY(COALESCE(aliases, ARRAY[]::text[])));
-- Randy → add "Randall" variant
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Randall'
)
WHERE LOWER(name) LIKE '%randy%'
  AND NOT ('Randall' = ANY(COALESCE(aliases, ARRAY[]::text[])));
-- Mitch → add "Mitchell" variant
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Mitchell'
)
WHERE LOWER(name) LIKE '%mitch%'
  AND LOWER(name) NOT LIKE '%mitchell%'
  AND NOT ('Mitchell' = ANY(COALESCE(aliases, ARRAY[]::text[])));
-- Also add reverse: if someone is named Deborah, add Debbie
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Debbie'
)
WHERE LOWER(name) LIKE '%deborah%'
  AND NOT ('Debbie' = ANY(COALESCE(aliases, ARRAY[]::text[])));
-- Randall → Randy
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Randy'
)
WHERE LOWER(name) LIKE '%randall%'
  AND NOT ('Randy' = ANY(COALESCE(aliases, ARRAY[]::text[])));
-- Mitchell → Mitch
UPDATE contacts
SET aliases = array_append(
  COALESCE(aliases, ARRAY[]::text[]),
  'Mitch'
)
WHERE LOWER(name) LIKE '%mitchell%'
  AND NOT ('Mitch' = ANY(COALESCE(aliases, ARRAY[]::text[])));
