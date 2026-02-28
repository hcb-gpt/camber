-- Comprehensive overwritten-generation audit for conversation_spans.
-- Focus: frequency, blast radius, and recoverability signals.

select
  count(*)::int as total_spans,
  count(*) filter (where is_superseded = false)::int as active_spans,
  count(*) filter (where is_superseded = true)::int as superseded_spans,
  round(
    100.0 * count(*) filter (where is_superseded = true) / nullif(count(*), 0),
    2
  ) as superseded_pct
from public.conversation_spans;

select
  segment_generation,
  count(*)::int as rows
from public.conversation_spans
group by segment_generation
order by segment_generation;

with per_interaction as (
  select
    interaction_id,
    max(segment_generation) as max_generation,
    count(*) filter (where is_superseded = false) as active_rows,
    count(*) as total_rows
  from public.conversation_spans
  group by interaction_id
)
select
  count(*)::int as interactions_total,
  count(*) filter (where max_generation >= 2)::int as interactions_gen2_plus,
  count(*) filter (where max_generation >= 3)::int as interactions_gen3_plus,
  count(*) filter (where max_generation >= 4)::int as interactions_gen4_plus
from per_interaction;

with ranked as (
  select
    cs.id,
    cs.interaction_id,
    cs.span_index,
    cs.segment_generation,
    max(cs.segment_generation) over (
      partition by cs.interaction_id, cs.span_index
    ) as max_gen
  from public.conversation_spans cs
),
bucketed as (
  select
    case
      when segment_generation = max_gen then 'latest'
      when segment_generation = max_gen - 1 then 'one_back'
      else 'two_plus_back'
    end as generation_bucket,
    case
      when segment_generation = max_gen then 1
      when segment_generation = max_gen - 1 then 2
      else 3
    end as bucket_order
  from ranked
)
select
  generation_bucket,
  count(*)::int as span_rows
from bucketed
group by generation_bucket, bucket_order
order by bucket_order;

with superseded as (
  select id, interaction_id, span_index
  from public.conversation_spans
  where is_superseded = true
),
active as (
  select interaction_id, span_index, max(segment_generation) as active_generation
  from public.conversation_spans
  where is_superseded = false
  group by interaction_id, span_index
)
select
  count(*)::int as superseded_total,
  count(*) filter (where a.interaction_id is null)::int as superseded_without_active_replacement,
  count(*) filter (where a.interaction_id is not null)::int as superseded_with_active_replacement
from superseded s
left join active a
  on a.interaction_id = s.interaction_id
 and a.span_index = s.span_index;

with keyed as (
  select
    interaction_id,
    span_index,
    max(segment_generation) as max_gen
  from public.conversation_spans
  group by interaction_id, span_index
),
latest as (
  select
    cs.id,
    cs.interaction_id,
    cs.span_index,
    cs.segment_generation,
    cs.is_superseded
  from public.conversation_spans cs
  join keyed k
    on k.interaction_id = cs.interaction_id
   and k.span_index = cs.span_index
   and k.max_gen = cs.segment_generation
)
select
  count(*)::int as latest_rows_total,
  count(*) filter (where is_superseded = false)::int as latest_rows_active,
  count(*) filter (where is_superseded = true)::int as latest_rows_superseded
from latest;

with keyed as (
  select
    interaction_id,
    span_index,
    max(segment_generation) as max_gen
  from public.conversation_spans
  group by interaction_id, span_index
)
select
  cs.id,
  cs.interaction_id,
  cs.span_index,
  cs.segment_generation,
  cs.is_superseded,
  k.max_gen
from public.conversation_spans cs
join keyed k
  on k.interaction_id = cs.interaction_id
 and k.span_index = cs.span_index
where cs.is_superseded = false
  and cs.segment_generation < k.max_gen;

select
  count(*)::int as pending_review_rows,
  count(*) filter (where cs.is_superseded = true)::int as pending_on_superseded_spans
from public.review_queue rq
left join public.conversation_spans cs
  on cs.id = rq.span_id
where rq.status = 'pending';

select
  count(*)::int as attrs_total,
  count(*) filter (where cs.is_superseded = true)::int as attrs_on_superseded_spans,
  count(*) filter (where cs.is_superseded = false)::int as attrs_on_active_spans
from public.span_attributions sa
left join public.conversation_spans cs
  on cs.id = sa.span_id;
