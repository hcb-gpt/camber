-- Proof pack: SMS channel coverage gap quant + v_redline_sms_thread_v2 patch
-- Receipt: p0_attrib_arch_fix__sms_channel_coverage_gap_quant_and_view_patch__20260228
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/p0_attrib_arch_fix_sms_channel_coverage_gap_quant_and_view_patch_proof_20260228.sql

\echo 'Q1) Last 14d daily gap rollup by channel (sms/sms_thread/call)'
select
  channel,
  sum(interactions_total)::int as interactions_total_14d,
  sum(interactions_with_spans)::int as interactions_with_spans_14d,
  sum(interactions_without_spans)::int as interactions_without_spans_14d,
  sum(interactions_with_effective_project)::int as interactions_with_effective_project_14d,
  sum(interactions_without_effective_project)::int as interactions_without_effective_project_14d
from public.v_channel_span_attribution_gap_daily
where event_date_utc >= (current_date - interval '14 days')
  and channel in ('sms', 'sms_thread', 'call')
group by channel
order by channel;

\echo 'Q2) REAL_DATA_POINTER #1: sms interaction_id with no spans'
select
  i.interaction_id,
  i.thread_key,
  i.event_at_utc,
  i.contact_phone
from public.interactions i
where i.channel = 'sms'
  and not exists (
    select 1
    from public.conversation_spans cs
    where cs.interaction_id = i.interaction_id
      and coalesce(cs.is_superseded, false) = false
  )
order by i.event_at_utc desc
limit 1;

\echo 'Q3) REAL_DATA_POINTER #2: sms_thread interaction_id with spans + attribution'
select
  i.interaction_id,
  i.thread_key,
  i.event_at_utc,
  vip.primary_project_id,
  i.project_id as interaction_project_id
from public.interactions i
left join public.v_interaction_primary_project vip
  on vip.interaction_id = i.interaction_id
where i.channel = 'sms_thread'
  and exists (
    select 1
    from public.conversation_spans cs
    where cs.interaction_id = i.interaction_id
      and coalesce(cs.is_superseded, false) = false
  )
  and coalesce(vip.primary_project_id, i.project_id) is not null
order by i.event_at_utc desc
limit 1;

\echo 'Q4) REAL_DATA_POINTER #3: one thread_id where sms_messages -> interactions(thread_key) join is clean'
with thread_msg as (
  select
    s.thread_id,
    count(*)::int as sms_message_count
  from public.sms_messages s
  where coalesce(s.thread_id, '') <> ''
  group by s.thread_id
), thread_interactions as (
  select
    i.thread_key as thread_id,
    count(distinct i.interaction_id)::int as sms_interaction_count
  from public.interactions i
  where i.channel = 'sms'
    and coalesce(i.thread_key, '') <> ''
  group by i.thread_key
)
select
  tm.thread_id,
  tm.sms_message_count,
  coalesce(ti.sms_interaction_count, 0) as sms_interaction_count,
  (ti.thread_id is not null) as join_clean
from thread_msg tm
left join thread_interactions ti
  on ti.thread_id = tm.thread_id
where ti.thread_id is not null
order by tm.sms_message_count desc
limit 1;

\echo 'Q5) View patch sample: v_redline_sms_thread_v2 effective project wiring'
select
  v.sms_id,
  v.thread_id,
  v.sms_thread_interaction_id,
  v.effective_project_id,
  v.effective_project_source,
  v.event_at_utc,
  v.contact_phone
from public.v_redline_sms_thread_v2 v
where v.effective_project_id is not null
order by v.event_at_utc desc
limit 10;
