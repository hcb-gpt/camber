-- Scheduling baseline metrics + proposal confidence scoring
-- Epics 0.2 / 1.3

create or replace view public.v_scheduling_baseline_metrics as
with scheduler as (
  select
    count(*)::bigint as total_scheduler_items,
    count(*) filter (where start_at_utc is not null or due_at_utc is not null)::bigint as scheduler_items_any_time,
    round(
      100.0 * count(*) filter (where start_at_utc is not null or due_at_utc is not null)
      / nullif(count(*), 0),
      2
    ) as pct_any_time
  from public.scheduler_items
),
open_loops as (
  select
    coalesce(jsonb_object_agg(loop_type, ct), '{}'::jsonb) as total_open_loops_by_type,
    count(*)::bigint as total_open_loops
  from (
    select loop_type, count(*) as ct
    from public.journal_open_loops
    where coalesce(status, 'open') <> 'closed'
    group by loop_type
  ) t
),
open_loops_status as (
  select coalesce(jsonb_object_agg(status_key, ct), '{}'::jsonb) as total_open_loops_by_status
  from (
    select coalesce(nullif(status, ''), 'UNKNOWN') as status_key, count(*) as ct
    from public.journal_open_loops
    group by coalesce(nullif(status, ''), 'UNKNOWN')
  ) s
),
temporal_claims as (
  select count(*)::bigint as total_temporal_claims
  from public.journal_claims jc
  where jc.active = true
    and (
      jc.claim_text ~* '\\b(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b'
      or jc.claim_text ~* '\\b(at|by|before|after)\\s+\\d{1,2}(:\\d{2})?\\s?(am|pm)?\\b'
      or jc.claim_text ~* '\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\b'
    )
),
commitment_signals as (
  select count(*)::bigint as total_commitment_signals
  from public.striking_signals
  where primary_signal_type = 'commitment'
),
sms_scheduling as (
  select count(*)::bigint as sms_scheduling_mentions
  from public.sms_messages sm
  where coalesce(sm.content, '') ~* '\\b(schedule|scheduled|reschedule|calendar|meeting|meet|eta|arrival|arrive|tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\\d{1,2}(:\\d{2})?\\s?(am|pm))\\b'
)
select
  now() at time zone 'utc' as measured_at_utc,
  s.total_scheduler_items,
  s.scheduler_items_any_time,
  s.pct_any_time,
  ol.total_open_loops,
  ol.total_open_loops_by_type,
  os.total_open_loops_by_status,
  tc.total_temporal_claims,
  cs.total_commitment_signals,
  ss.sms_scheduling_mentions
from scheduler s
cross join open_loops ol
cross join open_loops_status os
cross join temporal_claims tc
cross join commitment_signals cs
cross join sms_scheduling ss;

comment on view public.v_scheduling_baseline_metrics is
  'Weekly baseline health metrics for scheduling assistant readiness (Epics 0.2/1.3).';

create or replace function public.score_proposal(
  source_type text,
  evidence_json jsonb
)
returns table(confidence text, reason_codes text[])
language plpgsql
stable
as $$
declare
  has_explicit_datetime boolean := coalesce((evidence_json->>'has_explicit_datetime')::boolean, false);
  has_contact boolean := coalesce((evidence_json->>'has_contact')::boolean, false);
  sms_confirmation_48h boolean := coalesce((evidence_json->>'sms_confirmation_48h')::boolean, false);
  claim_confirmation_state text := lower(coalesce(evidence_json->>'claim_confirmation_state', ''));
  signal_type text := lower(coalesce(evidence_json->>'signal_type', ''));
  has_named_attendee boolean := coalesce((evidence_json->>'has_named_attendee')::boolean, false);
  has_time_no_confirmation boolean := coalesce((evidence_json->>'has_time_no_confirmation')::boolean, false);
  has_window_language boolean := coalesce((evidence_json->>'has_window_language')::boolean, false);
  has_temporal_reference boolean := coalesce((evidence_json->>'has_temporal_reference')::boolean, false);
  day_date_mismatch boolean := coalesce((evidence_json->>'day_date_mismatch')::boolean, false);
  window_without_date_anchor boolean := coalesce((evidence_json->>'window_without_date_anchor')::boolean, false);
  ambiguous_attendee boolean := coalesce((evidence_json->>'ambiguous_attendee')::boolean, false);
  conflicting_signals boolean := coalesce((evidence_json->>'conflicting_signals')::boolean, false);
  reasons text[] := array[]::text[];
  src text := lower(coalesce(source_type, ''));
begin
  -- Low-confidence overrides first.
  if day_date_mismatch then reasons := reasons || 'DAY_DATE_MISMATCH'; end if;
  if window_without_date_anchor then reasons := reasons || 'WINDOW_WITHOUT_DATE_ANCHOR'; end if;
  if ambiguous_attendee then reasons := reasons || 'AMBIGUOUS_ATTENDEE'; end if;
  if conflicting_signals then reasons := reasons || 'CONFLICTING_SIGNALS'; end if;

  if array_length(reasons, 1) is not null then
    return query select 'NEEDS_CLARIFICATION'::text, reasons;
    return;
  end if;

  -- High confidence conditions.
  if src = 'scheduler_item' and has_explicit_datetime and has_contact and sms_confirmation_48h then
    return query select 'CONFIRMED'::text, array['SCHEDULER_ITEM_CONFIRMED_SMS_48H']::text[];
    return;
  end if;

  if src = 'journal_claim' and claim_confirmation_state = 'confirmed' then
    return query select 'CONFIRMED'::text, array['JOURNAL_CLAIM_CONFIRMED']::text[];
    return;
  end if;

  if src = 'striking_signal' and signal_type = 'commitment' and has_explicit_datetime and has_named_attendee then
    return query select 'CONFIRMED'::text, array['COMMITMENT_SIGNAL_DATETIME_ATTENDEE']::text[];
    return;
  end if;

  -- Medium confidence defaults.
  if src = 'scheduler_item' and (has_time_no_confirmation or has_explicit_datetime) then
    return query select 'TENTATIVE'::text, array['SCHEDULER_ITEM_TIME_WITHOUT_CONFIRMATION']::text[];
    return;
  end if;

  if src = 'journal_claim' and claim_confirmation_state in ('reported', 'mentioned', '') then
    return query select 'TENTATIVE'::text, array['JOURNAL_CLAIM_NOT_CONFIRMED']::text[];
    return;
  end if;

  if has_window_language then
    return query select 'TENTATIVE'::text, array['WINDOW_LANGUAGE_PRESENT']::text[];
    return;
  end if;

  if src = 'open_loop' and has_temporal_reference then
    return query select 'TENTATIVE'::text, array['OPEN_LOOP_TEMPORAL_REFERENCE']::text[];
    return;
  end if;

  -- Conservative fallback.
  return query select 'NEEDS_CLARIFICATION'::text, array['INSUFFICIENT_EVIDENCE']::text[];
end;
$$;

comment on function public.score_proposal(text, jsonb) is
  'Scores scheduling proposal confidence into CONFIRMED/TENTATIVE/NEEDS_CLARIFICATION with reason codes (Epic 1.3).';
