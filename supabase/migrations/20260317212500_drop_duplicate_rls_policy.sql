-- Drop redundant RLS policy on gmail_financial_candidates
-- The table has two identical policies for service_role ('service_role_only' and 'service_role_all_gmail_financial_candidates').
-- Removing the duplicate reduces policy evaluation overhead on every query.

DROP POLICY IF EXISTS "service_role_all_gmail_financial_candidates" ON public.gmail_financial_candidates;
