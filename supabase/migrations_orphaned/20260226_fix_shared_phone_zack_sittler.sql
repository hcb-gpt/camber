-- =============================================================================
-- Migration: Fix shared phone number on Zack Sittler's contact record
-- Date:      2026-02-26
-- Author:    STRAT / DATA
-- Status:    ALREADY APPLIED LIVE 2026-02-26 ~04:25 UTC
-- =============================================================================
--
-- BUG SUMMARY
-- -----------
-- contacts.phone for Zack Sittler (id = 86009ead-70c5-4232-9940-9d85eb567f26)
-- was set to '+17066889158', which is the shared Beside owner line (the main
-- company number). Because the interaction-linking logic matches on phone,
-- every inbound/outbound call and SMS touching that shared line was attributed
-- to Zack — even when the actual counterparty was someone else entirely.
--
-- Impact:
--   - 170 phantom interactions attributed to Zack (real count: ~168)
--   - 97 phantom SMS messages attributed to Zack (real count: ~23)
--   - Inflated redline_thread / redline_contacts view counts
--   - Downstream claim counts and belief_claims inflated accordingly
--
-- Root cause: The shared owner line was stored as Zack's primary phone instead
-- of his personal cell (+16074375546). This likely happened during initial
-- contact creation from a call where Zack was reached via the owner line.
--
-- Fix:
--   1. Update Zack's contact record to his real cell number.
--   2. Clear contact_id on all interactions that were matched solely because
--      they touched the shared owner line.
--
-- =============================================================================

-- ALREADY APPLIED LIVE 2026-02-26 ~04:25 UTC

-- Step 1: Correct Zack Sittler's phone number from the shared owner line
--         to his actual cell, and record the change in notes.
UPDATE contacts
SET phone           = '+16074375546',
    secondary_phone = NULL,
    notes           = notes || E'\n[2026-02-26] Fixed shared-phone bug: was +17066889158 (Beside owner line), changed to personal cell +16074375546.'
WHERE id    = '86009ead-70c5-4232-9940-9d85eb567f26'
  AND phone = '+17066889158';

-- Step 2a: Clear contact attribution on interactions that were linked to Zack
--          solely via the shared owner line phone number.
UPDATE interactions
SET contact_id    = NULL,
    contact_name  = NULL,
    contact_phone = NULL
WHERE contact_id    = '86009ead-70c5-4232-9940-9d85eb567f26'
  AND contact_phone = '+17066889158';

-- Step 2b: Clear contact attribution on interactions where the underlying
--          calls_raw record shows other_party_phone = the shared owner line.
--          These rows may not have contact_phone set but were still incorrectly
--          linked via contact_id.
UPDATE interactions
SET contact_id   = NULL,
    contact_name = NULL
WHERE contact_id = '86009ead-70c5-4232-9940-9d85eb567f26'
  AND interaction_id IN (
      SELECT interaction_id::text
      FROM calls_raw
      WHERE other_party_phone = '+17066889158'
  );

-- =============================================================================
-- POST-FIX VERIFICATION (run manually, not part of migration)
-- =============================================================================
-- SELECT phone, secondary_phone FROM contacts WHERE id = '86009ead-70c5-4232-9940-9d85eb567f26';
--   Expected: phone = '+16074375546', secondary_phone = NULL
--
-- SELECT count(*) FROM interactions WHERE contact_id = '86009ead-70c5-4232-9940-9d85eb567f26';
--   Expected: ~168 (real Zack interactions only, no phantom owner-line matches)
--
-- SELECT count(*) FROM redline_thread WHERE contact_id = '86009ead-70c5-4232-9940-9d85eb567f26';
--   Expected: reduced from ~842 to real count
-- =============================================================================
