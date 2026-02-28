-- Tighten Redline write-path RLS exposure.
-- Remove broad anon/public write policies and revoke write grants from anon/authenticated.

begin;

-- claim_grades: remove anon write exposure (iOS MVP policy drift)
drop policy if exists "anon_insert_grades" on public.claim_grades;
drop policy if exists "anon_update_grades" on public.claim_grades;

-- redline_settings: remove broad UPDATE exposure
drop policy if exists "anon_update_settings" on public.redline_settings;

-- corrections: remove broad ALL exposure
drop policy if exists "corrections_all" on public.corrections;

-- Principle-of-least-privilege: no direct client writes to these tables.
revoke insert, update, delete on table public.claim_grades from anon, authenticated;
revoke insert, update, delete on table public.redline_settings from anon, authenticated;
revoke insert, update, delete on table public.corrections from anon, authenticated;

commit;

