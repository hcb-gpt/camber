-- Beside direct-read parity metrics (v0)
--
-- Provides a simple, additive 72-hour window parity view between:
-- - Beside SSOT direct-read events (public.beside_thread_events)
-- - Existing Zapier/Camber tables for the same events
--
-- Matching rules (v0):
-- - messages: beside_thread_events.beside_event_id (msg_*) == sms_messages.message_id
-- - calls:    beside_thread_events.beside_event_id (cll_*) == calls_raw.interaction_id
--
-- Output:
-- - direct_read_total_72h: denominator
-- - matched_total_72h: numerator
-- - orphan_total_72h: direct-read events with no match in fallback table
-- - match_rate_72h: matched / total

begin;

-- NOTE: Production already has a newer, wider v_beside_direct_read_parity_72h definition.
-- CREATE OR REPLACE VIEW cannot *drop* columns, so we only create the v0 view if it does not exist.
do $do$
begin
  if to_regclass('public.v_beside_direct_read_parity_72h') is null then
    execute $sql$
      create view public.v_beside_direct_read_parity_72h as
      with direct_events as (
        select
          bte.beside_event_id,
          bte.beside_event_type,
          bte.occurred_at_utc
        from public.beside_thread_events bte
        where bte.source = 'beside_direct_read'
          and bte.beside_event_type in ('message', 'call')
          and bte.occurred_at_utc >= (now() - interval '72 hours')
      ),
      matched as (
        select
          de.beside_event_id,
          de.beside_event_type,
          de.occurred_at_utc,
          case
            when de.beside_event_type = 'message'
              then exists (
                select 1
                from public.sms_messages sm
                where sm.message_id = de.beside_event_id
              )
            when de.beside_event_type = 'call'
              then exists (
                select 1
                from public.calls_raw cr
                where cr.interaction_id = de.beside_event_id
              )
            else false
          end as is_matched
        from direct_events de
      )
      select
        m.beside_event_type,
        count(*) as direct_read_total_72h,
        count(*) filter (where m.is_matched) as matched_total_72h,
        count(*) filter (where not m.is_matched) as orphan_total_72h,
        case
          when count(*) = 0 then 0::double precision
          else (count(*) filter (where m.is_matched))::double precision / count(*)::double precision
        end as match_rate_72h
      from matched m
      group by 1
      order by 1;
    $sql$;
  end if;
end;
$do$;

comment on view public.v_beside_direct_read_parity_72h is
  'Parity metrics for Beside direct-read vs Zapier/Camber tables over the last 72h. v0: exact-id joins msg_* and cll_*.';

grant select on public.v_beside_direct_read_parity_72h to service_role;

commit;
