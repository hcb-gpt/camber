-- P5: Redline top candidates materialized view + refresh schedule
-- Purpose: prioritize contacts with the highest unresolved attribution backlog.

begin;

drop materialized view if exists public.redline_top_candidates;

create materialized view public.redline_top_candidates as
with pending_queue as (
  select
    rq.id as review_queue_id,
    rq.created_at,
    coalesce(rq.interaction_id, cs.interaction_id) as interaction_key
  from public.review_queue rq
  left join public.conversation_spans cs
    on cs.id = rq.span_id
  where rq.status = 'pending'
),
pending_with_interaction as (
  select
    pq.review_queue_id,
    pq.created_at,
    i.contact_id,
    i.contact_name,
    i.contact_phone,
    i.event_at_utc
  from pending_queue pq
  join lateral (
    select
      i.contact_id,
      i.contact_name,
      i.contact_phone,
      i.event_at_utc
    from public.interactions i
    where i.interaction_id = pq.interaction_key
       or i.id::text = pq.interaction_key
    order by case when i.interaction_id = pq.interaction_key then 0 else 1 end
    limit 1
  ) i on true
),
pending_by_contact as (
  select
    pwi.contact_id,
    coalesce(c.name, pwi.contact_name) as contact_name,
    coalesce(c.phone, pwi.contact_phone) as contact_phone,
    count(distinct pwi.review_queue_id)::integer as pending_review_count,
    min(pwi.created_at) as oldest_pending_review
  from pending_with_interaction pwi
  left join public.contacts c
    on c.id = pwi.contact_id
  where pwi.contact_id is not null
  group by
    pwi.contact_id,
    coalesce(c.name, pwi.contact_name),
    coalesce(c.phone, pwi.contact_phone)
),
interaction_totals as (
  select
    i.contact_id,
    count(*)::integer as total_interaction_count,
    max(i.event_at_utc) as last_activity
  from public.interactions i
  where i.contact_id is not null
  group by i.contact_id
)
select
  p.contact_id,
  p.contact_name,
  p.contact_phone,
  p.pending_review_count,
  coalesce(it.total_interaction_count, 0) as total_interaction_count,
  it.last_activity,
  p.oldest_pending_review
from pending_by_contact p
left join interaction_totals it
  on it.contact_id = p.contact_id
where p.pending_review_count > 0
order by
  p.pending_review_count desc,
  p.oldest_pending_review asc nulls last,
  p.contact_name asc;

create unique index redline_top_candidates_contact_id_uq
  on public.redline_top_candidates (contact_id);

create index redline_top_candidates_pending_desc_idx
  on public.redline_top_candidates (pending_review_count desc, oldest_pending_review asc);

comment on materialized view public.redline_top_candidates is
  'Contacts prioritized for redline review by unresolved pending review_queue workload.';

comment on column public.redline_top_candidates.pending_review_count is
  'Count of distinct pending review_queue rows currently open for the contact.';

comment on column public.redline_top_candidates.oldest_pending_review is
  'Oldest pending review_queue.created_at timestamp for the contact.';

create or replace function public.refresh_redline_top_candidates()
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refreshed_at timestamptz := now();
begin
  refresh materialized view public.redline_top_candidates;
  return v_refreshed_at;
end;
$$;

comment on function public.refresh_redline_top_candidates() is
  'On-demand refresh for public.redline_top_candidates materialized view.';

grant select on public.redline_top_candidates to service_role;
grant execute on function public.refresh_redline_top_candidates() to service_role;

-- Schedule: every 15 minutes
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'redline_top_candidates_refresh_15min'
      ) then
        perform cron.schedule(
          'redline_top_candidates_refresh_15min',
          '*/15 * * * *',
          $$select public.refresh_redline_top_candidates();$$
        );
      end if;
    exception
      when others then
        raise notice 'redline_top_candidates cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
