-- Fix score_proposal reason_codes accumulation

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
  if day_date_mismatch then reasons := array_append(reasons, 'DAY_DATE_MISMATCH'); end if;
  if window_without_date_anchor then reasons := array_append(reasons, 'WINDOW_WITHOUT_DATE_ANCHOR'); end if;
  if ambiguous_attendee then reasons := array_append(reasons, 'AMBIGUOUS_ATTENDEE'); end if;
  if conflicting_signals then reasons := array_append(reasons, 'CONFLICTING_SIGNALS'); end if;

  if array_length(reasons, 1) is not null then
    return query select 'NEEDS_CLARIFICATION'::text, reasons;
    return;
  end if;

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

  return query select 'NEEDS_CLARIFICATION'::text, array['INSUFFICIENT_EVIDENCE']::text[];
end;
$$;
