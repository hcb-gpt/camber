-- UX bugbash quick DB proof pack (read-only)
-- Usage:
--   scripts/query.sh --file scripts/sql/ux_bugbash_data_quick_proof_20260228.sql
-- Optional override:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
--     -v project_id='372777a7-47b6-49c0-95b3-37a6ef3513a0' \
--     -v interaction_id='cll_06E6TTM3N9T4S7FFE2YE4V9XF4' \
--     -v span_id='21f4c399-0b9b-4adf-b0ec-d179d4de67e6' \
--     -v review_queue_id='99b3847b-a1d9-43c9-83cd-07a9a1bf9785' \
--     -v contact_id='35ab3df2-543f-4cec-b24e-a1009254bd69' \
--     -f scripts/sql/ux_bugbash_data_quick_proof_20260228.sql

\if :{?project_id}
\else
\set project_id ''
\endif
\if :{?interaction_id}
\else
\set interaction_id ''
\endif
\if :{?span_id}
\else
\set span_id ''
\endif
\if :{?review_queue_id}
\else
\set review_queue_id ''
\endif
\if :{?contact_id}
\else
\set contact_id ''
\endif

\echo 'Q1) Assistant/project metric contract snapshot'
select
  project_id,
  project_name,
  interactions_7d,
  active_journal_claims as claims_legacy,
  active_journal_claims_total,
  active_journal_claims_7d,
  open_loops as open_loops_legacy,
  open_loops_total,
  open_loops_7d,
  pending_reviews as pending_reviews_legacy,
  pending_reviews_span_total,
  pending_reviews_queue_total,
  pending_reviews_queue_7d
from public.v_project_feed
where project_id::text = nullif(:'project_id', '');

\echo 'Q2) Interaction ownership + attribution by span'
with target as (
  select
    i.interaction_id,
    i.project_id as interaction_project_id,
    p.name as interaction_project_name,
    i.contact_id,
    i.contact_name,
    i.channel,
    i.event_at_utc
  from public.interactions i
  left join public.projects p
    on p.id = i.project_id
  where i.interaction_id = nullif(:'interaction_id', '')
  limit 1
),
span_attr as (
  select
    cs.interaction_id,
    sa.applied_project_id,
    pp.name as applied_project_name,
    count(*) as span_count,
    max(sa.confidence) as max_confidence
  from public.conversation_spans cs
  left join public.span_attributions sa
    on sa.span_id = cs.id
  left join public.projects pp
    on pp.id = sa.applied_project_id
  where cs.interaction_id = nullif(:'interaction_id', '')
    and coalesce(cs.is_superseded, false) = false
  group by cs.interaction_id, sa.applied_project_id, pp.name
)
select
  t.*,
  sa.applied_project_id,
  sa.applied_project_name,
  sa.span_count,
  sa.max_confidence
from target t
left join span_attr sa
  on sa.interaction_id = t.interaction_id
order by sa.span_count desc nulls last, sa.max_confidence desc nulls last;

\echo 'Q3) Review queue item contract check'
select
  rq.id as review_queue_id,
  rq.status,
  rq.created_at,
  rq.updated_at,
  rq.resolved_at,
  rq.interaction_id,
  rq.span_id,
  rq.module,
  rq.reasons,
  rq.reason_codes,
  rq.hit_count,
  i.contact_id,
  i.contact_name,
  i.project_id as interaction_project_id,
  p.name as interaction_project_name,
  cs.span_index,
  cs.word_count
from public.review_queue rq
left join public.interactions i
  on i.interaction_id = rq.interaction_id
left join public.projects p
  on p.id = i.project_id
left join public.conversation_spans cs
  on cs.id = rq.span_id
where rq.id::text = nullif(:'review_queue_id', '');

\echo 'Q4) Span existence + latest attribution evidence'
with attr as (
  select
    sa.*,
    row_number() over (partition by sa.span_id order by sa.attributed_at desc nulls last) as rn
  from public.span_attributions sa
  where sa.span_id::text = nullif(:'span_id', '')
)
select
  cs.id as span_id,
  cs.interaction_id,
  cs.span_index,
  cs.word_count,
  cs.is_superseded,
  cs.created_at,
  a.applied_project_id,
  p.name as applied_project_name,
  a.confidence,
  a.attributed_at,
  a.model_id,
  a.prompt_version
from public.conversation_spans cs
left join attr a
  on a.span_id = cs.id
 and a.rn = 1
left join public.projects p
  on p.id = a.applied_project_id
where cs.id::text = nullif(:'span_id', '');

\echo 'Q5) Contact thread evidence footprint'
select
  i.channel,
  count(*) as interaction_count,
  max(i.event_at_utc) as latest_event_at_utc,
  min(i.event_at_utc) as oldest_event_at_utc
from public.interactions i
where i.contact_id::text = nullif(:'contact_id', '')
group by i.channel
order by interaction_count desc;

\echo 'Q6) Interaction call + span coverage'
with interaction_row as (
  select
    i.interaction_id,
    i.contact_id,
    i.contact_name,
    i.project_id,
    p.name as project_name,
    i.channel,
    i.event_at_utc
  from public.interactions i
  left join public.projects p
    on p.id = i.project_id
  where i.interaction_id = nullif(:'interaction_id', '')
),
call_raw as (
  select
    c.interaction_id,
    c.direction,
    c.other_party_name,
    c.event_at_utc as call_event_at_utc,
    c.recording_url
  from public.calls_raw c
  where c.interaction_id = nullif(:'interaction_id', '')
),
span_cov as (
  select
    cs.interaction_id,
    count(*) filter (where coalesce(cs.is_superseded, false) = false) as active_span_count,
    max(cs.word_count) as max_span_word_count
  from public.conversation_spans cs
  where cs.interaction_id = nullif(:'interaction_id', '')
  group by cs.interaction_id
)
select
  ir.interaction_id,
  ir.contact_id,
  ir.contact_name,
  ir.project_id,
  ir.project_name,
  ir.channel,
  ir.event_at_utc,
  cr.direction as call_direction,
  cr.other_party_name,
  (cr.recording_url is not null) as has_recording_url,
  sc.active_span_count,
  sc.max_span_word_count
from interaction_row ir
left join call_raw cr
  on cr.interaction_id = ir.interaction_id
left join span_cov sc
  on sc.interaction_id = ir.interaction_id;
