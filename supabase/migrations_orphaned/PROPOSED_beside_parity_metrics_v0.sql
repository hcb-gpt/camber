-- PROPOSED (not applied): Beside direct-read parity metrics v0
--
-- Purpose:
-- - Provide an explicit, queryable definition of "match within 72h" and orphan
--   counts between Beside direct-read SSOT tables and existing Zapier-derived
--   CAMBER tables.
--
-- Notes:
-- - This file lives in supabase/migrations_orphaned/ intentionally.
--   Promote into supabase/migrations/ with a new timestamp version when STRAT
--   approves and a guarded claim exists.
--
-- Assumptions (current prod schema observed via PostgREST):
-- - public.sms_messages has:
--     - message_id (msg_*)
--     - beside_conversation_id (thread identifier)
-- - public.calls_raw has:
--     - interaction_id (cll_*)
--
-- Matching strategy (v0):
-- - Messages: beside_thread_events.beside_event_id == sms_messages.message_id
-- - Calls:    beside_thread_events.beside_event_id == calls_raw.interaction_id
--
-- Window:
-- - occurred_at_utc >= now() - interval '72 hours'

begin;

create or replace view public.v_beside_direct_read_parity_72h as
with direct_events as (
  select
    bte.beside_event_id,
    bte.beside_room_id,
    bte.beside_event_type,
    bte.occurred_at_utc,
    bte.ingest_run_id,
    bte.captured_at_utc
  from public.beside_thread_events bte
  where bte.source = 'beside_direct_read'
    and bte.occurred_at_utc >= (now() - interval '72 hours')
),
message_matches as (
  select
    de.*,
    sm.id as camber_sms_message_row_id
  from direct_events de
  left join public.sms_messages sm
    on de.beside_event_type = 'message'
   and sm.message_id = de.beside_event_id
),
call_matches as (
  select
    mm.*,
    cr.interaction_id as camber_call_interaction_id
  from message_matches mm
  left join public.calls_raw cr
    on mm.beside_event_type = 'call'
   and cr.interaction_id = mm.beside_event_id
)
select
  cm.beside_event_type,
  count(*) as direct_read_total_72h,
  count(*) filter (
    where (cm.beside_event_type = 'message' and cm.camber_sms_message_row_id is not null)
       or (cm.beside_event_type = 'call' and cm.camber_call_interaction_id is not null)
  ) as matched_total_72h,
  count(*) filter (
    where (cm.beside_event_type = 'message' and cm.camber_sms_message_row_id is null)
       or (cm.beside_event_type = 'call' and cm.camber_call_interaction_id is null)
  ) as orphan_total_72h,
  case
    when count(*) = 0 then 0::double precision
    else (
      count(*) filter (
        where (cm.beside_event_type = 'message' and cm.camber_sms_message_row_id is not null)
           or (cm.beside_event_type = 'call' and cm.camber_call_interaction_id is not null)
      )::double precision
      / count(*)::double precision
    )
  end as match_rate_72h
from call_matches cm
where cm.beside_event_type in ('message', 'call')
group by 1
order by 1;

comment on view public.v_beside_direct_read_parity_72h is
  'Parity metrics for Beside direct-read vs Zapier CAMBER tables over the last 72h. v0: message_id/interation_id exact-id matching.';

commit;

