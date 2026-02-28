-- pipeline_heartbeat: single-row view for pipeline health monitoring
-- Returns staleness metrics for calls, SMS, interactions, review queue, and diagnostics

CREATE OR REPLACE VIEW pipeline_heartbeat AS
SELECT
  -- Call staleness
  (SELECT max(event_at_utc) FROM calls_raw WHERE channel = 'call')
    AS last_call_event,
  (SELECT max(ingested_at_utc) FROM calls_raw WHERE channel = 'call')
    AS last_call_ingested,
  EXTRACT(EPOCH FROM (now() - (SELECT max(event_at_utc) FROM calls_raw WHERE channel = 'call'))) / 60
    AS call_stale_minutes,

  -- SMS staleness
  (SELECT max(sent_at) FROM sms_messages)
    AS last_sms_event,
  (SELECT max(ingested_at) FROM sms_messages)
    AS last_sms_ingested,
  EXTRACT(EPOCH FROM (now() - (SELECT max(sent_at) FROM sms_messages))) / 60
    AS sms_stale_minutes,

  -- Interaction staleness
  (SELECT max(event_at_utc) FROM interactions WHERE event_at_utc IS NOT NULL)
    AS last_interaction,
  EXTRACT(EPOCH FROM (now() - (SELECT max(event_at_utc) FROM interactions WHERE event_at_utc IS NOT NULL))) / 60
    AS interaction_stale_minutes,

  -- Review queue depth
  (SELECT count(*) FROM review_queue WHERE status = 'pending')
    AS pending_review_count,

  -- Most recent diagnostic error
  (SELECT message FROM diagnostic_logs WHERE log_level = 'error' ORDER BY created_at DESC LIMIT 1)
    AS last_diagnostic_error,

  -- Pipeline health flag: both call and SMS fresh within 120 minutes
  (
    EXTRACT(EPOCH FROM (now() - (SELECT max(event_at_utc) FROM calls_raw WHERE channel = 'call'))) / 60 < 120
    AND
    EXTRACT(EPOCH FROM (now() - (SELECT max(sent_at) FROM sms_messages))) / 60 < 120
  ) AS pipeline_ok;

COMMENT ON VIEW pipeline_heartbeat IS 'Single-row pipeline health dashboard. pipeline_ok=true when both call and SMS staleness < 120 minutes.';
