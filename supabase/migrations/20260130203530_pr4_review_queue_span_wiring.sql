-- PR-4: Review queue span wiring
-- Adds span_id for idempotent span-level review items
-- Creates v_review_queue_spans view as product surface
--
-- Source: DATA_STRAT_20260130T0810Z_pr4_review_queue_view_and_schema.sql

begin;
-- 1) Add span_id column to review_queue (if missing)
alter table public.review_queue add column if not exists span_id uuid;
-- 2) Create unique index on span_id for idempotent upserts
-- (allows multiple NULL span_id rows for legacy items)
create unique index if not exists review_queue_span_id_uq
  on public.review_queue (span_id)
  where span_id is not null;
-- 3) Add index for status + created_at ordering
create index if not exists review_queue_status_created_idx
  on public.review_queue (status, created_at desc);
-- 4) Product surface view: review items joined to spans + latest attribution
create or replace view public.v_review_queue_spans as
with latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    sa.created_at as sa_created_at,
    sa.decision,
    sa.confidence,
    sa.project_id as predicted_project_id,
    sa.applied_project_id,
    sa.attribution_lock,
    sa.needs_review,
    sa.anchors as anchors_json,
    sa.candidates as candidates_json,
    sa.raw_response as context_receipt
  from public.span_attributions sa
  order by sa.span_id, sa.created_at desc
)
select
  rq.id                              as review_queue_id,
  rq.status                          as review_status,
  rq.reasons                         as reason_codes,
  rq.created_at                      as review_created_at,
  rq.resolved_at                     as review_resolved_at,
  rq.span_id                         as span_id,
  rq.interaction_id                  as interaction_id,

  -- Span fields (best-effort)
  cs.id                              as span_row_id,
  cs.start_ms                        as span_start_ms,
  cs.end_ms                          as span_end_ms,

  left(
    coalesce(
      cs.transcript_segment,
      cs.transcript_text,
      rq.context_payload->>'transcript_snippet',
      ''
    ),
    600
  )                                 as transcript_snippet,

  -- Interaction fields (best-effort)
  i.id                              as interaction_row_id,
  coalesce(i.channel, 'unknown')    as channel,
  coalesce(i.event_at_utc::text, i.occurred_at_utc::text, i.created_at::text) as interaction_time,

  -- Latest attribution
  la.sa_created_at                  as attribution_created_at,
  la.decision                       as decision,
  la.confidence                     as confidence,
  la.predicted_project_id           as predicted_project_id,
  la.applied_project_id             as applied_project_id,
  la.attribution_lock               as attribution_lock,
  la.needs_review                   as needs_review,

  -- Model debug payloads
  la.anchors_json                   as anchors_json,
  la.candidates_json                as candidates_json

from public.review_queue rq
left join public.conversation_spans cs
  on cs.id = rq.span_id
left join public.interactions i
  on i.id = coalesce(rq.interaction_id, cs.interaction_id)
left join latest_attr la
  on la.span_id = rq.span_id;
comment on view public.v_review_queue_spans is
  'Product surface for review queue. Joins review items to spans, attributions, and interactions.';
commit;
