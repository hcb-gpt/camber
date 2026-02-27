-- Migration: pipeline_staleness_alert_cron
-- Creates a function + pg_cron job that monitors pipeline freshness
-- and inserts a TRAM escalation when call or SMS data is stale during business hours.

CREATE OR REPLACE FUNCTION public.check_pipeline_staleness()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_last_call      timestamptz;
  v_last_sms       timestamptz;
  v_now            timestamptz := now();
  v_hour           int         := extract(hour from v_now);
  v_call_age_min   int;
  v_sms_age_min    int;
  v_call_stale     boolean     := false;
  v_sms_stale      boolean     := false;
  v_details        text        := '';
  v_receipt        text;
  v_existing       int;
BEGIN
  -- Only fire during business hours: 13-23 UTC (8am-6pm EST)
  IF v_hour < 13 OR v_hour > 23 THEN
    RETURN;
  END IF;

  -- Check last call event
  SELECT max(event_at_utc) INTO v_last_call
  FROM calls_raw
  WHERE channel = 'call';

  -- Check last SMS
  SELECT max(sent_at) INTO v_last_sms
  FROM sms_messages;

  -- Compute ages in minutes
  v_call_age_min := extract(epoch from (v_now - v_last_call))::int / 60;
  v_sms_age_min  := extract(epoch from (v_now - v_last_sms))::int / 60;

  -- Threshold: 120 minutes (2 hours)
  IF v_last_call IS NOT NULL AND v_call_age_min > 120 THEN
    v_call_stale := true;
  END IF;

  IF v_last_sms IS NOT NULL AND v_sms_age_min > 120 THEN
    v_sms_stale := true;
  END IF;

  -- Nothing stale, exit
  IF NOT v_call_stale AND NOT v_sms_stale THEN
    RETURN;
  END IF;

  -- Idempotency: skip if there is already an unacked staleness alert in the last 2 hours
  SELECT count(*) INTO v_existing
  FROM tram_messages
  WHERE subject = 'pipeline_staleness_alert'
    AND kind = 'escalation'
    AND (acked = false OR acked IS NULL)
    AND created_at > v_now - interval '2 hours';

  IF v_existing > 0 THEN
    RETURN;
  END IF;

  -- Build details
  IF v_call_stale THEN
    v_details := v_details || 'CALLS: last event ' || v_call_age_min || ' min ago (' || v_last_call::text || '). ';
  END IF;
  IF v_sms_stale THEN
    v_details := v_details || 'SMS: last event ' || v_sms_age_min || ' min ago (' || v_last_sms::text || '). ';
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
    'Pipeline staleness detected during business hours. ' || v_details || 'Threshold: 2h. Checked at ' || v_now::text,
    true,
    false,
    v_now
  );
END;
$$;

-- Schedule: every 30 minutes
SELECT cron.schedule(
  'pipeline_staleness_alert_30m',
  '*/30 * * * *',
  'SELECT public.check_pipeline_staleness()'
);
