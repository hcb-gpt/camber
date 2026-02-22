-- attribution_audit_sample_v1.sql
--
-- Purpose:
-- - Emit a small random sample of recent attributed spans (default N=10, last 48h)
-- - Include enough provenance pointers for reconstruction and review
--
-- Safe execution (read-only):
--   scripts/query.sh --file scripts/sql/attribution_audit_sample_v1.sql
--
-- Deterministic sample option (seeded):
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--     -v sample_seed=0.314159 -v sample_limit=10 \
--     -f scripts/sql/attribution_audit_sample_v1.sql

\if :{?sample_limit}
\else
\set sample_limit 10
\endif

\if :{?sample_seed}
select setseed((:'sample_seed')::double precision);
select (:'sample_seed')::double precision as sample_seed_used;
\else
select null::double precision as sample_seed_used;
\endif

with latest_attr_per_span as (
  select
    sa.id as span_attribution_id,
    sa.span_id,
    coalesce(sa.applied_project_id, sa.project_id) as attributed_project_id,
    sa.decision,
    sa.needs_review,
    sa.attribution_lock,
    sa.attribution_source,
    sa.confidence,
    sa.applied_at_utc,
    sa.attributed_at,
    sa.anchors,
    sa.match_positions,
    sa.matched_terms,
    row_number() over (
      partition by sa.span_id
      order by coalesce(sa.applied_at_utc, sa.attributed_at, cs.created_at) desc, sa.id desc
    ) as rn
  from public.span_attributions sa
  join public.conversation_spans cs
    on cs.id = sa.span_id
  where cs.is_superseded = false
    and coalesce(sa.applied_project_id, sa.project_id) is not null
    and coalesce(sa.applied_at_utc, sa.attributed_at, cs.created_at) >= now() - interval '48 hours'
),
audit_packet as (
  select
    cs.id as span_id,
    cs.interaction_id,
    la.attributed_project_id,
    null::uuid as evidence_event_id,
    cs.span_index,
    cs.char_start,
    cs.char_end,
    cs.time_start_sec,
    cs.time_end_sec,
    left(regexp_replace(coalesce(cs.transcript_segment, ''), '\s+', ' ', 'g'), 280) as transcript_snippet,
    md5(coalesce(cs.transcript_segment, '')) as transcript_md5,
    jsonb_build_object(
      'table', 'public.conversation_spans',
      'span_id', cs.id,
      'interaction_id', cs.interaction_id,
      'span_index', cs.span_index,
      'char_start', cs.char_start,
      'char_end', cs.char_end
    ) as span_text_pointer,
    cs.created_at as span_created_at,
    coalesce(la.applied_at_utc, la.attributed_at, cs.created_at) as attribution_ts_utc,
    la.decision,
    la.needs_review,
    la.attribution_lock,
    la.attribution_source,
    la.confidence,
    la.span_attribution_id,
    jsonb_array_length(coalesce(la.anchors, '[]'::jsonb)) as anchors_count,
    left(regexp_replace(coalesce(la.anchors::text, ''), '\s+', ' ', 'g'), 280) as anchors_preview,
    left(regexp_replace(coalesce(la.match_positions::text, ''), '\s+', ' ', 'g'), 280) as match_positions_preview,
    la.matched_terms
  from latest_attr_per_span la
  join public.conversation_spans cs
    on cs.id = la.span_id
  where la.rn = 1
),
sampled as (
  select *
  from audit_packet
  order by random()
  limit :sample_limit
)
select
  span_id,
  interaction_id,
  attributed_project_id,
  evidence_event_id,
  span_index,
  char_start,
  char_end,
  time_start_sec,
  time_end_sec,
  span_text_pointer,
  transcript_md5,
  transcript_snippet,
  span_created_at,
  attribution_ts_utc,
  decision,
  needs_review,
  attribution_lock,
  attribution_source,
  confidence,
  span_attribution_id,
  anchors_count,
  anchors_preview,
  match_positions_preview,
  matched_terms
from sampled
order by attribution_ts_utc desc, interaction_id, span_index;
