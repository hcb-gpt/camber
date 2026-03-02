-- Reduce false-positive staleness alerts when ingest is fresh but event timestamps lag.
-- Escalate only when both event-time and ingest-time freshness exceed threshold.

CREATE OR REPLACE FUNCTION public.check_pipeline_staleness()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_last_call_event      timestamptz;
  v_last_call_ingested   timestamptz;
  v_last_sms_event       timestamptz;
  v_last_sms_ingested    timestamptz;
  v_now                  timestamptz := now();
  v_hour                 int         := extract(hour from v_now);

  v_call_event_age_min   int;
  v_call_ingest_age_min  int;
  v_sms_event_age_min    int;
  v_sms_ingest_age_min   int;

  v_call_stale           boolean     := false;
  v_sms_stale            boolean     := false;
  v_call_soft            boolean     := false;
  v_sms_soft             boolean     := false;

  v_details              text        := '';
  v_receipt              text;
  v_existing             int;
BEGIN
  -- Business hours only: 13-23 UTC (8am-6pm EST in standard time).
  IF v_hour < 13 OR v_hour > 23 THEN
    RETURN;
  END IF;

  SELECT max(event_at_utc), max(ingested_at_utc)
  INTO v_last_call_event, v_last_call_ingested
  FROM calls_raw
  WHERE channel = 'call';

  SELECT max(sent_at), max(ingested_at)
  INTO v_last_sms_event, v_last_sms_ingested
  FROM sms_messages;

  v_call_event_age_min := CASE
    WHEN v_last_call_event IS NULL THEN NULL
    ELSE extract(epoch from (v_now - v_last_call_event))::int / 60
  END;
  v_call_ingest_age_min := CASE
    WHEN v_last_call_ingested IS NULL THEN NULL
    ELSE extract(epoch from (v_now - v_last_call_ingested))::int / 60
  END;
  v_sms_event_age_min := CASE
    WHEN v_last_sms_event IS NULL THEN NULL
    ELSE extract(epoch from (v_now - v_last_sms_event))::int / 60
  END;
  v_sms_ingest_age_min := CASE
    WHEN v_last_sms_ingested IS NULL THEN NULL
    ELSE extract(epoch from (v_now - v_last_sms_ingested))::int / 60
  END;

  -- Hard stale requires both event and ingest to be stale.
  -- Soft stale indicates event timestamps are old while ingest remains fresh.
  IF v_last_call_event IS NOT NULL AND v_call_event_age_min > 120 THEN
    IF v_last_call_ingested IS NULL OR v_call_ingest_age_min > 120 THEN
      v_call_stale := true;
    ELSE
      v_call_soft := true;
    END IF;
  END IF;

  IF v_last_sms_event IS NOT NULL AND v_sms_event_age_min > 120 THEN
    IF v_last_sms_ingested IS NULL OR v_sms_ingest_age_min > 120 THEN
      v_sms_stale := true;
    ELSE
      v_sms_soft := true;
    END IF;
  END IF;

  -- No hard stale = no escalation.
  IF NOT v_call_stale AND NOT v_sms_stale THEN
    RETURN;
  END IF;

  -- Idempotency: skip if there is already an unacked staleness alert in the last 2 hours.
  SELECT count(*) INTO v_existing
  FROM tram_messages
  WHERE subject = 'pipeline_staleness_alert'
    AND kind = 'escalation'
    AND (acked = false OR acked IS NULL)
    AND created_at > v_now - interval '2 hours';

  IF v_existing > 0 THEN
    RETURN;
  END IF;

  IF v_call_stale THEN
    v_details := v_details || format(
      'CALLS: event=%s (%s min) ingest=%s (%s min). ',
      coalesce(v_last_call_event::text, 'null'),
      coalesce(v_call_event_age_min::text, 'null'),
      coalesce(v_last_call_ingested::text, 'null'),
      coalesce(v_call_ingest_age_min::text, 'null')
    );
  ELSIF v_call_soft THEN
    v_details := v_details || format(
      'CALLS_SOFT: event=%s (%s min) ingest_fresh=%s (%s min). ',
      coalesce(v_last_call_event::text, 'null'),
      coalesce(v_call_event_age_min::text, 'null'),
      coalesce(v_last_call_ingested::text, 'null'),
      coalesce(v_call_ingest_age_min::text, 'null')
    );
  END IF;

  IF v_sms_stale THEN
    v_details := v_details || format(
      'SMS: event=%s (%s min) ingest=%s (%s min). ',
      coalesce(v_last_sms_event::text, 'null'),
      coalesce(v_sms_event_age_min::text, 'null'),
      coalesce(v_last_sms_ingested::text, 'null'),
      coalesce(v_sms_ingest_age_min::text, 'null')
    );
  ELSIF v_sms_soft THEN
    v_details := v_details || format(
      'SMS_SOFT: event=%s (%s min) ingest_fresh=%s (%s min). ',
      coalesce(v_last_sms_event::text, 'null'),
      coalesce(v_sms_event_age_min::text, 'null'),
      coalesce(v_last_sms_ingested::text, 'null'),
      coalesce(v_sms_ingest_age_min::text, 'null')
    );
  END IF;

  v_receipt := 'staleness_alert__' || to_char(v_now, 'YYYYMMDD_HH24MI');

  INSERT INTO tram_messages (
    receipt,
    "to",
    "from",
    subject,
    kind,
    priority,
    thread,
    content,
    ack_required,
    acked,
    created_at
  ) VALUES (
    v_receipt,
    'STRAT',
    'DATA',
    'pipeline_staleness_alert',
    'escalation',
    'high',
    'pipeline_health',
    'Pipeline staleness detected during business hours. ' || v_details || 'Threshold: 2h (event + ingest). Checked at ' || v_now::text,
    true,
    false,
    v_now
  );
END;
$$;
