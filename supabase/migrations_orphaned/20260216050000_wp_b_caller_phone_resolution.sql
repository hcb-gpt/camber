-- Migration: WP-B Caller Phone Resolution
-- Owner: wp-b-worker (world-model-prep)
-- Purpose: Resolve NULL contact_name on interactions via phone matching against contacts.
--          Pure SQL, no LLM. Uses multiple phone normalizations.
--
-- Before counts (2026-02-16):
--   contact_name IS NOT NULL: 872
--   contact_name IS NULL:     213
--   contact_id IS NOT NULL:   875
--   contact_id IS NULL:       210
--
-- Expected resolution paths:
--   Path 1: contact_id FK already set but contact_name NULL (3 rows: April Chambers)
--   Path 2: Phone match to contacts with real names (1 row: Mark Vaeth)
--   Path 3: Phone match to contacts with placeholder names -- sets contact_id only (7 rows)
--
-- After counts (VERIFIED 2026-02-16):
--   contact_name IS NOT NULL: 876  (+4, was 872)
--   contact_name IS NULL:     209  (-4, was 213)
--   contact_id IS NOT NULL:   883  (+8, was 875)
--   contact_id IS NULL:       202  (-8, was 210)
--
-- Resolution breakdown:
--   3x April Chambers (contact_id FK, Path 1)
--   1x Mark Vaeth (exact phone match, Path 2)
--   4x contact_id-only links to "Unknown" contacts (Path 2, name preserved as NULL)
--   Remaining 209 NULL contact_name: no matching contact in contacts table

BEGIN;

-- ============================================================
-- Path 1: Resolve contact_name via existing contact_id FK
-- These interactions already have contact_id set but contact_name is NULL.
-- ============================================================
UPDATE interactions i
SET contact_name = c.name
FROM contacts c
WHERE i.contact_id = c.id
  AND i.contact_name IS NULL
  AND c.name IS NOT NULL
  AND c.name NOT LIKE 'Unknown - %';

-- ============================================================
-- Path 2: Resolve contact_name AND contact_id via phone matching
-- Multi-normalization strategy (priority order):
--   1. Exact match on phone
--   2. Digits-only match (strip all non-digits)
--   3. Last-10-digits match (handles +1 prefix differences)
--   4. Secondary phone digits match
--   5. Secondary phone last-10 match
--
-- Only sets contact_name for contacts with real names (not "Unknown - ...").
-- Uses DISTINCT ON to pick highest-priority match per interaction.
-- ============================================================
WITH best_match AS (
  SELECT DISTINCT ON (i.id)
    i.id AS interaction_uuid,
    c.id AS matched_contact_id,
    c.name AS matched_name,
    CASE
      WHEN c.phone = i.contact_phone THEN 1           -- exact
      WHEN c.phone_digits = regexp_replace(i.contact_phone, '[^0-9]', '', 'g') THEN 2  -- digits
      WHEN LENGTH(regexp_replace(i.contact_phone, '[^0-9]', '', 'g')) >= 10
           AND RIGHT(c.phone_digits, 10) = RIGHT(regexp_replace(i.contact_phone, '[^0-9]', '', 'g'), 10) THEN 3  -- last10
      WHEN c.secondary_phone_digits = regexp_replace(i.contact_phone, '[^0-9]', '', 'g') THEN 4  -- secondary digits
      WHEN c.secondary_phone_digits != ''
           AND LENGTH(regexp_replace(i.contact_phone, '[^0-9]', '', 'g')) >= 10
           AND RIGHT(c.secondary_phone_digits, 10) = RIGHT(regexp_replace(i.contact_phone, '[^0-9]', '', 'g'), 10) THEN 5  -- secondary last10
    END AS match_priority
  FROM interactions i
  JOIN contacts c ON (
    c.phone = i.contact_phone
    OR c.phone_digits = regexp_replace(i.contact_phone, '[^0-9]', '', 'g')
    OR (LENGTH(regexp_replace(i.contact_phone, '[^0-9]', '', 'g')) >= 10
        AND RIGHT(c.phone_digits, 10) = RIGHT(regexp_replace(i.contact_phone, '[^0-9]', '', 'g'), 10))
    OR c.secondary_phone_digits = regexp_replace(i.contact_phone, '[^0-9]', '', 'g')
    OR (c.secondary_phone_digits != ''
        AND LENGTH(regexp_replace(i.contact_phone, '[^0-9]', '', 'g')) >= 10
        AND RIGHT(c.secondary_phone_digits, 10) = RIGHT(regexp_replace(i.contact_phone, '[^0-9]', '', 'g'), 10))
  )
  WHERE i.contact_name IS NULL
    AND i.contact_phone IS NOT NULL
  ORDER BY i.id, match_priority
)
UPDATE interactions i
SET
  contact_name = CASE
    WHEN bm.matched_name NOT LIKE 'Unknown - %' THEN bm.matched_name
    ELSE i.contact_name  -- keep NULL; don't overwrite with placeholder
  END,
  contact_id = COALESCE(i.contact_id, bm.matched_contact_id)
FROM best_match bm
WHERE i.id = bm.interaction_uuid;

COMMIT;

-- After counts (run manually to verify):
-- SELECT
--   COUNT(*) FILTER (WHERE contact_name IS NOT NULL) AS contact_name_not_null_after,
--   COUNT(*) FILTER (WHERE contact_name IS NULL) AS contact_name_null_after,
--   COUNT(*) FILTER (WHERE contact_id IS NOT NULL) AS contact_id_not_null_after,
--   COUNT(*) FILTER (WHERE contact_id IS NULL) AS contact_id_null_after
-- FROM interactions;
