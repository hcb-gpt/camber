-- Add ingest-aware warning guardrails for pipeline staleness alerts.
-- Goal: suppress false critical alerts when event timestamps are stale but
-- ingest timestamps are fresh and recent rows are mostly missing event times.

CREATE OR REPLACE FUNCTION public.check_pipeline_staleness()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_last_call_event            timestamptz;
  v_last_call_ingested         timestamptz;
  v_last_sms_event             timestamptz;
  v_last_sms_ingested          timestamptz;
  v_now                        timestamptz := now();
  v_hour                       int         := extract(hour from v_now);

  v_call_event_age_min         int;
  v_call_ingest_age_min        int;
  v_sms_event_age_min          int;
  v_sms_ingest_age_min         int;

  v_call_recent_rows_120       int := 0;
  v_call_recent_null_event_120 int := 0;
  v_sms_recent_rows_120        int := 0;
  v_sms_recent_null_event_120  int := 0;
  v_call_null_ratio_120        numeric := 0;
  v_sms_null_ratio_120         numeric := 0;

  v_call_hard_stale            boolean := false;
  v_sms_hard_stale             boolean := false;
  v_call_warning               boolean := false;
  v_sms_warning                boolean := false;

  v_subject                    text;
  v_kind                       text;
  v_priority                   text;
  v_receipt_prefix             text;
  v_receipt                    text;
  v_filename                   text;
  v_existing                   int;
  v_details                    text := '';
BEGIN
  -- Business hours only: 13-23 UTC (8am-6pm EST in standard time).
  IF v_hour < 13 OR v_hour > 23 THEN
    RETURN;
  END IF;

  SELECT
    max(event_at_utc),
    max(coalesce(ingested_at_utc, source_received_at_utc, received_at_utc))
  INTO
    v_last_call_event,
    v_last_call_ingested
  FROM calls_raw
  WHERE channel = 'call';

  SELECT
    count(*),
    count(*) FILTER (WHERE event_at_utc IS NULL)
  INTO
    v_call_recent_rows_120,
    v_call_recent_null_event_120
  FROM calls_raw
  WHERE channel = 'call'
    AND coalesce(ingested_at_utc, source_received_at_utc, received_at_utc) >= v_now - interval '120 minutes';

  SELECT
    max(sent_at),
    max(coalesce(ingested_at, sent_at))
  INTO
    v_last_sms_event,
    v_last_sms_ingested
  FROM sms_messages;

  SELECT
    count(*),
    count(*) FILTER (WHERE sent_at IS NULL)
  INTO
    v_sms_recent_rows_120,
    v_sms_recent_null_event_120
  FROM sms_messages
  WHERE coalesce(ingested_at, sent_at) >= v_now - interval '120 minutes';

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

  IF v_call_recent_rows_120 > 0 THEN
    v_call_null_ratio_120 := v_call_recent_null_event_120::numeric / v_call_recent_rows_120::numeric;
  END IF;
  IF v_sms_recent_rows_120 > 0 THEN
    v_sms_null_ratio_120 := v_sms_recent_null_event_120::numeric / v_sms_recent_rows_120::numeric;
  END IF;

  -- Classification for CALLS:
  -- - HARD stale: event stale and ingest stale/missing OR ingest fresh but recent rows are not mostly null-event.
  -- - WARNING: event stale, ingest fresh, and recent rows are mostly null-event (>=50%).
  IF v_last_call_event IS NOT NULL AND v_call_event_age_min > 120 THEN
    IF v_last_call_ingested IS NULL OR v_call_ingest_age_min > 120 THEN
      v_call_hard_stale := true;
    ELSIF v_call_recent_rows_120 > 0 AND v_call_null_ratio_120 >= 0.5 THEN
      v_call_warning := true;
    ELSE
      v_call_hard_stale := true;
    END IF;
  END IF;

  -- Classification for SMS uses the same guardrail (typically null ratio is near 0).
  IF v_last_sms_event IS NOT NULL AND v_sms_event_age_min > 120 THEN
    IF v_last_sms_ingested IS NULL OR v_sms_ingest_age_min > 120 THEN
      v_sms_hard_stale := true;
    ELSIF v_sms_recent_rows_120 > 0 AND v_sms_null_ratio_120 >= 0.5 THEN
      v_sms_warning := true;
    ELSE
      v_sms_hard_stale := true;
    END IF;
  END IF;

  -- No hard stale + no warning = no TRAM emission.
  IF NOT v_call_hard_stale AND NOT v_sms_hard_stale AND NOT v_call_warning AND NOT v_sms_warning THEN
    RETURN;
  END IF;

  IF v_call_hard_stale OR v_sms_hard_stale THEN
    v_subject := 'pipeline_staleness_alert';
    v_kind := 'escalation';
    v_priority := 'high';
    v_receipt_prefix := 'staleness_alert__';
  ELSE
    v_subject := 'pipeline_staleness_warning';
    v_kind := 'status_update';
    v_priority := 'normal';
    v_receipt_prefix := 'staleness_warning__';
  END IF;

  -- Idempotency: one unacked alert/warning per 2-hour window per subject.
  SELECT count(*) INTO v_existing
  FROM tram_messages
  WHERE subject = v_subject
    AND kind = v_kind
    AND (acked = false OR acked IS NULL)
    AND created_at > v_now - interval '2 hours';

  IF v_existing > 0 THEN
    RETURN;
  END IF;

  IF v_call_hard_stale THEN
    v_details := v_details || format(
      'CALLS_HARD: event=%s (%s min), ingest=%s (%s min), recent_rows_120=%s, null_event_ratio_120=%.2f. ',
      coalesce(v_last_call_event::text, 'null'),
      coalesce(v_call_event_age_min::text, 'null'),
      coalesce(v_last_call_ingested::text, 'null'),
      coalesce(v_call_ingest_age_min::text, 'null'),
      v_call_recent_rows_120,
      coalesce(v_call_null_ratio_120, 0)
    );
  ELSIF v_call_warning THEN
    v_details := v_details || format(
      'CALLS_WARNING: event=%s (%s min), ingest_fresh=%s (%s min), recent_rows_120=%s, null_event_ratio_120=%.2f. ',
      coalesce(v_last_call_event::text, 'null'),
      coalesce(v_call_event_age_min::text, 'null'),
      coalesce(v_last_call_ingested::text, 'null'),
      coalesce(v_call_ingest_age_min::text, 'null'),
      v_call_recent_rows_120,
      coalesce(v_call_null_ratio_120, 0)
    );
  END IF;

  IF v_sms_hard_stale THEN
    v_details := v_details || format(
      'SMS_HARD: event=%s (%s min), ingest=%s (%s min), recent_rows_120=%s, null_event_ratio_120=%.2f. ',
      coalesce(v_last_sms_event::text, 'null'),
      coalesce(v_sms_event_age_min::text, 'null'),
      coalesce(v_last_sms_ingested::text, 'null'),
      coalesce(v_sms_ingest_age_min::text, 'null'),
      v_sms_recent_rows_120,
      coalesce(v_sms_null_ratio_120, 0)
    );
  ELSIF v_sms_warning THEN
    v_details := v_details || format(
      'SMS_WARNING: event=%s (%s min), ingest_fresh=%s (%s min), recent_rows_120=%s, null_event_ratio_120=%.2f. ',
      coalesce(v_last_sms_event::text, 'null'),
      coalesce(v_sms_event_age_min::text, 'null'),
      coalesce(v_last_sms_ingested::text, 'null'),
      coalesce(v_sms_ingest_age_min::text, 'null'),
      v_sms_recent_rows_120,
      coalesce(v_sms_null_ratio_120, 0)
    );
  END IF;

  v_receipt := v_receipt_prefix || to_char(v_now, 'YYYYMMDD_HH24MI');
  v_filename := format(
    '%s__to_strat__from_data__prio_%s__kind_%s__pipeline_staleness_monitor.md',
    to_char(v_now AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
    v_priority,
    v_kind
  );

  INSERT INTO tram_messages (
    filename,
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
    v_filename,
    v_receipt,
    'STRAT',
    'DATA',
    v_subject,
    v_kind,
    v_priority,
    'pipeline_health',
    'Pipeline staleness monitor fired. ' || v_details ||
      'Threshold: 120 minutes with ingest-aware null-event guardrail. Checked at ' || v_now::text,
    CASE WHEN v_kind = 'escalation' THEN true ELSE false END,
    false,
    v_now
  );
END;
$$;
