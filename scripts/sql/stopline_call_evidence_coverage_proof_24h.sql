-- Stopline proof: call evidence coverage for interactions referenced by active spans (last 24h).
--
-- Run:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   "${PSQL_PATH:-psql}" "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/stopline_call_evidence_coverage_proof_24h.sql

with spans_24h as (
  select distinct
    cs.interaction_id
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
    and coalesce(cs.created_at, now()) >= (now() - interval '24 hours')
),
coverage_rows as (
  select
    s.interaction_id,
    ee.evidence_event_id,
    ee.source_run_id,
    ee.payload_ref,
    ee.integrity_hash,
    ee.created_at
  from spans_24h s
  left join lateral (
    select
      e.evidence_event_id,
      e.source_run_id,
      e.payload_ref,
      e.integrity_hash,
      e.created_at
    from public.evidence_events e
    where e.source_type = 'call'
      and e.source_id = s.interaction_id
      and coalesce(e.transcript_variant, 'baseline') = 'baseline'
    order by e.created_at desc nulls last
    limit 1
  ) ee on true
),
summary as (
  select
    count(*)::int as interactions_with_spans_24h,
    count(*) filter (
      where evidence_event_id is not null
    )::int as interactions_with_evidence_event,
    count(*) filter (
      where evidence_event_id is null
    )::int as interactions_missing_evidence_event,
    round(
      (count(*) filter (where evidence_event_id is null)::numeric / nullif(count(*), 0)),
      4
    ) as missing_rate_24h
  from coverage_rows
),
coverage_ids as (
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'interaction_id', c.interaction_id,
          'evidence_event_id', c.evidence_event_id,
          'source_run_id', c.source_run_id
        )
        order by c.interaction_id
      ) filter (
        where c.evidence_event_id is not null
      ),
      '[]'::jsonb
    ) as coverage_event_ids_24h
  from coverage_rows c
),
lane_ids as (
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'interaction_id', c.interaction_id,
          'evidence_event_id', c.evidence_event_id,
          'source_run_id', c.source_run_id
        )
        order by c.interaction_id
      ) filter (
        where c.source_run_id in (
          'backfill:20260223009100',
          'stopline_backfill:20260223009200',
          'stopline_guard:20260223009200'
        )
      ),
      '[]'::jsonb
    ) as created_or_guarded_event_ids
  from coverage_rows c
),
missing_examples as (
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object('interaction_id', c.interaction_id)
        order by c.interaction_id
      ),
      '[]'::jsonb
    ) as missing_interaction_ids
  from coverage_rows c
  where c.evidence_event_id is null
)
select
  now() at time zone 'utc' as snapshot_ts_utc,
  s.interactions_with_spans_24h,
  s.interactions_with_evidence_event,
  s.interactions_missing_evidence_event,
  s.missing_rate_24h,
  cv.coverage_event_ids_24h,
  li.created_or_guarded_event_ids,
  me.missing_interaction_ids
from summary s
cross join coverage_ids cv
cross join lane_ids li
cross join missing_examples me;
