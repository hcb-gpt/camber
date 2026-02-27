-- Enable Supabase Realtime on 4 Redline tables for iOS WebSocket subscriptions
-- Single-user MVP: permissive USING(true) policies for anon

-- 1. Add tables to Realtime publication (interactions already present)
ALTER PUBLICATION supabase_realtime ADD TABLE public.claim_grades;
ALTER PUBLICATION supabase_realtime ADD TABLE public.journal_claims;
ALTER PUBLICATION supabase_realtime ADD TABLE public.sms_messages;

-- 2. Add anon SELECT policies (claim_grades already has anon_read_grades)
CREATE POLICY anon_read_interactions ON public.interactions FOR SELECT TO anon USING (true);
CREATE POLICY anon_read_journal_claims ON public.journal_claims FOR SELECT TO anon USING (true);
CREATE POLICY anon_read_sms_messages ON public.sms_messages FOR SELECT TO anon USING (true);;
