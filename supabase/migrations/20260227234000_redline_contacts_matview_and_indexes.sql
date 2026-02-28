begin;
-- Materialize the expensive redline_contacts view so redline-thread contacts endpoint
-- can query a stable relation (refreshed via pg_cron).
create materialized view public.redline_contacts_matview as
select *
from public.redline_contacts;
-- Required for fast lookups + enables REFRESH MATERIALIZED VIEW CONCURRENTLY.
create unique index if not exists redline_contacts_matview_contact_id_uq
  on public.redline_contacts_matview (contact_id);
-- Composite indexes to accelerate redline_contacts definition and related hot paths.
create index if not exists idx_review_queue_status_span_id
  on public.review_queue (status, span_id);
create index if not exists idx_review_queue_status_interaction_id
  on public.review_queue (status, interaction_id);
create index if not exists idx_conversation_spans_interaction_superseded_span_index
  on public.conversation_spans (interaction_id, is_superseded, span_index);
-- redline-thread runs via service_role key; ensure the matview is selectable.
grant select on public.redline_contacts_matview to service_role;
-- Refresh every minute (additive; view remains the fallback SSOT).
do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'refresh_redline_contacts_matview_1m'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'refresh_redline_contacts_matview_1m',
        '*/1 * * * *',
        $$refresh materialized view concurrently public.redline_contacts_matview;$$
      );
    exception
      when others then
        raise notice 'refresh_redline_contacts_matview_1m cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;
commit;
