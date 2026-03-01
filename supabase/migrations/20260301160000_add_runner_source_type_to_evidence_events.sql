-- Fix: Add 'runner' to evidence_events source_type CHECK constraint.
-- The review-swarm-runner v0.1.1 emits per-run instrumentation with source_type='runner',
-- but the CHECK constraint only allowed: call, sms, photo, email, buildertrend, manual, lineage, scheduler.
-- The insert was silently failing due to fire-and-forget pattern.

BEGIN;

ALTER TABLE public.evidence_events
  DROP CONSTRAINT IF EXISTS evidence_events_source_type_check;

ALTER TABLE public.evidence_events
  ADD CONSTRAINT evidence_events_source_type_check
  CHECK (source_type = ANY (ARRAY[
    'call'::text,
    'sms'::text,
    'photo'::text,
    'email'::text,
    'buildertrend'::text,
    'manual'::text,
    'lineage'::text,
    'scheduler'::text,
    'runner'::text
  ]));

COMMIT;
