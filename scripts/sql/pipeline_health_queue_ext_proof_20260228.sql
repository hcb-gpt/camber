-- Proof pack for queue_ext__pipeline_health_ops_tooling_requeue_and_dlq__20260228

select
  span_id,
  interaction_id,
  status,
  hit_count,
  reasons,
  reason_codes,
  updated_at
from public.review_queue
where span_id = '756764aa-9ade-4f61-884d-083e152aa490'::uuid;

select
  id,
  span_id,
  interaction_id,
  retry_count,
  age_hours,
  dlq_reason,
  last_enqueued_at
from public.v_hard_drop_dlq_open
order by last_enqueued_at desc
limit 20;

select
  id,
  monitor_name,
  fired_at,
  acked,
  metric_snapshot
from public.monitor_alerts
where monitor_name = 'hard_drop_sla_monitor_tuned_v1'
order by fired_at desc
limit 10;

select
  jobid,
  jobname,
  schedule,
  active,
  command
from cron.job
where jobname = 'hard_drop_sla_monitor_tuned_hourly';
