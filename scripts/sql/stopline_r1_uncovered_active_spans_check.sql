-- Stopline R1 coverage proof pack.
-- Covered active span = has any span_attributions row OR has pending review_queue row.
-- Run: scripts/query.sh --file scripts/sql/stopline_r1_uncovered_active_spans_check.sql

-- 1) Global stopline summary counts
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.span_index,
    cs.transcript_segment
  from public.conversation_spans cs
  where cs.is_superseded = false
),
attr as (
  select distinct sa.span_id
  from public.span_attributions sa
),
rq as (
  select distinct rq.span_id
  from public.review_queue rq
  where rq.span_id is not null
    and rq.status = 'pending'
)
select
  count(*)::bigint as active_spans,
  count(*) filter (where attr.span_id is not null and rq.span_id is not null)::bigint
    as both_attributed_and_in_review,
  count(*) filter (where attr.span_id is not null or rq.span_id is not null)::bigint
    as attributed_only_or_both,
  count(*) filter (where rq.span_id is not null)::bigint
    as in_review_only_or_both,
  count(*) filter (where attr.span_id is null and rq.span_id is null)::bigint
    as neither_attributed_nor_in_review
from active_spans s
left join attr on attr.span_id = s.span_id
left join rq on rq.span_id = s.span_id;

-- 2) Top interactions with uncovered active spans (for triage)
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id
  from public.conversation_spans cs
  where cs.is_superseded = false
),
attr as (
  select distinct sa.span_id
  from public.span_attributions sa
),
rq as (
  select distinct rq.span_id
  from public.review_queue rq
  where rq.span_id is not null
    and rq.status = 'pending'
)
select
  s.interaction_id,
  count(*)::bigint as uncovered_active_spans
from active_spans s
left join attr on attr.span_id = s.span_id
left join rq on rq.span_id = s.span_id
where attr.span_id is null
  and rq.span_id is null
group by s.interaction_id
order by uncovered_active_spans desc, s.interaction_id
limit 200;

-- 3) Uncovered active span detail list
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    cs.span_index,
    cs.transcript_segment
  from public.conversation_spans cs
  where cs.is_superseded = false
),
attr as (
  select distinct sa.span_id
  from public.span_attributions sa
),
rq as (
  select distinct rq.span_id
  from public.review_queue rq
  where rq.span_id is not null
    and rq.status = 'pending'
)
select
  s.interaction_id,
  s.span_id,
  s.span_index,
  left(coalesce(s.transcript_segment, ''), 280) as transcript_snippet
from active_spans s
left join attr on attr.span_id = s.span_id
left join rq on rq.span_id = s.span_id
where attr.span_id is null
  and rq.span_id is null
order by s.interaction_id, s.span_index nulls last, s.span_id
limit 2000;
