-- Owner: DATA-5
-- Order: orders__data5__fix5_phase_seed_v0_schedule_milestones__20260216
-- Goal:
-- - Seed schedule milestones for Woodbery + Moss in project_facts.
-- - Use 3-5 schedule.milestone entries per project.
-- - Use source marker source_batch_id='phase_seed_v0' via evidence metadata.
--
-- IMPORTANT
-- - This file MUTATES DATA. Do NOT run via scripts/query.sh.
-- - Run with psql (or equivalent) with appropriate credentials.
-- - This script ends with ROLLBACK by default. Change to COMMIT to apply.
--
-- Note:
-- - No top-level source_batch_id column exists on project_facts; batch metadata is
--   carried in evidence_events.metadata.
--
begin;

with params as (
  select *
  from (
    values
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, '2025-09-04T00:00:00Z'::timestamptz, '2025-09-04T00:00:00Z'::timestamptz, ('manual_seed:phase_seed_v0:woodbery:' || encode(gen_random_bytes(4), 'hex'))::text),
      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, '2025-09-01T04:00:00Z'::timestamptz, '2025-09-01T04:00:00Z'::timestamptz, ('manual_seed:phase_seed_v0:moss:' || encode(gen_random_bytes(4), 'hex'))::text)
  ) as p(project_id, as_of_at, observed_at, source_id)
),
manual_evidence as (
  insert into public.evidence_events (
    source_type,
    source_id,
    transcript_variant,
    occurred_at_utc,
    metadata
  )
  select
    'manual',
    p.source_id,
    null,
    p.as_of_at,
    jsonb_build_object(
      'seed_script', 'scripts/backfills/phase_seed_v0.sql',
      'seed_kind', 'phase_seed_v0',
      'project_id', p.project_id::text,
      'source_batch_id', 'phase_seed_v0',
      'notes', 'Seeded milestone schedule anchors for routing/temporal disambiguation.'
    )
  from params p
  returning p.project_id, evidence_event_id
),
seed_facts as (
  select *
  from (
    values
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'permit_submitted', '2025-09-10', 'planned', 'Estimated from typical Woodbery sequencing; verified by manual seed context.'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'foundation_complete', '2025-10-20', 'planned', 'Estimated from typical Woodbery sequencing; manually estimated.'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'framing_start', '2025-11-15', 'planned', 'Estimated from typical Woodbery sequencing; manually estimated.'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'rough_meps_passed', '2026-02-08', 'planned', 'Estimated from typical Woodbery sequencing; manually estimated.'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'final_inspection', '2026-06-01', 'planned', 'Estimated from typical Woodbery sequencing; manually estimated.'),

      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, 'permit_submitted', '2025-09-08', 'planned', 'Estimated from typical Moss sequencing; manually estimated.'),
      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, 'foundation_complete', '2025-10-12', 'planned', 'Estimated from typical Moss sequencing; manually estimated.'),
      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, 'framing_start', '2025-11-01', 'planned', 'Estimated from typical Moss sequencing; manually estimated.'),
      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, 'interior_complete', '2026-03-01', 'planned', 'Estimated from typical Moss sequencing; manually estimated.'),
      ('47cb7720-9495-4187-8220-a8100c3b67aa'::uuid, 'final_inspection', '2026-05-20', 'planned', 'Estimated from typical Moss sequencing; manually estimated.')
  ) as v(
    project_id,
    milestone_name,
    milestone_date,
    milestone_status,
    notes
  )
),
inserted as (
  insert into public.project_facts (
    project_id,
    as_of_at,
    observed_at,
    fact_kind,
    fact_payload,
    evidence_event_id
  )
  select
    sf.project_id,
    p.as_of_at,
    p.observed_at,
    'schedule.milestone'::text,
    jsonb_build_object(
      'milestone', sf.milestone_name,
      'date', sf.milestone_date,
      'status', sf.milestone_status,
      'source_batch_id', 'phase_seed_v0',
      'notes', sf.notes,
      'confidence', 0.88
    ),
    me.evidence_event_id
  from seed_facts sf
  join params p on p.project_id = sf.project_id
  join manual_evidence me on me.project_id = sf.project_id
  where not exists (
    select 1
    from public.project_facts pf
    where pf.project_id = sf.project_id
      and pf.fact_kind = 'schedule.milestone'
      and pf.fact_payload = jsonb_build_object(
        'milestone', sf.milestone_name,
        'date', sf.milestone_date,
        'status', sf.milestone_status,
        'source_batch_id', 'phase_seed_v0',
        'notes', sf.notes,
        'confidence', 0.88
      )
      and pf.as_of_at = p.as_of_at
      and pf.observed_at = p.observed_at
      and pf.evidence_event_id is not distinct from me.evidence_event_id
  )
  returning project_id, fact_kind
)
select
  i.project_id::text as project_id,
  i.fact_kind,
  count(*)::integer as inserted_rows
from inserted i
group by i.project_id, i.fact_kind;

-- Default: do not apply.
rollback;
