-- Expand evidence_events.source_type to include 'scheduler'
-- for review-swarm-scheduler skip/run observability (v1.1.0+)

begin;

alter table public.evidence_events
  drop constraint if exists evidence_events_source_type_check;

alter table public.evidence_events
  add constraint evidence_events_source_type_check
  check (source_type in ('call', 'sms', 'photo', 'email', 'buildertrend', 'manual', 'lineage', 'scheduler'));

commit;
