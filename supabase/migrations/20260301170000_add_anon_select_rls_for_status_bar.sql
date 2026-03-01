-- Add anon SELECT policies for tram_presence and tram_messages.
-- Required by orbit-status.sh tmux status bar which uses the Supabase anon key
-- to query fleet status and TRAM queue depth from Chad's local machine.

BEGIN;

CREATE POLICY "anon_select_fleet" ON public.tram_presence
  FOR SELECT
  TO anon
  USING (true);

CREATE POLICY "anon_select_tram_status" ON public.tram_messages
  FOR SELECT
  TO anon
  USING (true);

COMMIT;
