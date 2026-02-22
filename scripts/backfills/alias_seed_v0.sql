-- Owner: DATA-5
-- Order: orders__data5__fix3_alias_seed_v0_project_facts__20260216
-- Goal:
-- - Seed alias/nickname mappings for Woodbery Residence in project_facts.
-- - Use fact_kind='scope.alias' and source provenance marker 'alias_seed_v0'.
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
  select
    '7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid as project_id,
    '2025-09-04T00:00:00Z'::timestamptz as as_of_at,
    '2025-09-04T00:00:00Z'::timestamptz as observed_at,
    ('manual_seed:alias_seed_v0:' || encode(gen_random_bytes(8), 'hex'))::text as source_id,
    'alias_seed_v0'::text as source_batch_id
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
      'seed_script', 'scripts/backfills/alias_seed_v0.sql',
      'seed_kind', 'alias_seed_v0',
      'project_id', p.project_id::text,
      'source_batch_id', p.source_batch_id,
      'notes', 'Woodbery Residence alias/nickname seed derived from known project shorthand references.'
    )
  from params p
  returning p.project_id, evidence_event_id
),
seed_facts as (
  select *
  from (
    values
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'Lou''s house', 'nickname'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'Lou''s place', 'nickname'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'Enterprise', 'street_alias'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'Enterprise job', 'site_alias'),
      ('7db5e186-7dda-4c2c-b85e-7235b67e06d8'::uuid, 'Enterprise Road', 'road_alias')
  ) as v(
    project_id,
    alias_value,
    alias_type
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
    'scope.alias'::text,
    jsonb_build_object(
      'alias', sf.alias_value,
      'alias_type', sf.alias_type,
      'source_batch_id', p.source_batch_id,
      'confidence', 0.97,
      'notes', 'Alias seed from known Woodbery shorthand references (manual seed).'
    ),
    me.evidence_event_id
  from seed_facts sf
  join params p on p.project_id = sf.project_id
  join manual_evidence me on me.project_id = sf.project_id
  where not exists (
    select 1
    from public.project_facts pf
    where pf.project_id = sf.project_id
      and pf.fact_kind = 'scope.alias'
      and pf.fact_payload = jsonb_build_object(
        'alias', sf.alias_value,
        'alias_type', sf.alias_type,
        'source_batch_id', p.source_batch_id,
        'confidence', 0.97,
        'notes', 'Alias seed from known Woodbery shorthand references (manual seed).'
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
