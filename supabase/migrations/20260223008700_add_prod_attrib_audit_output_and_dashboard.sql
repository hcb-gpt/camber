-- Standing production attribution audit: reviewer output schema + 7d dashboard tile view.

alter table public.eval_samples
  add column if not exists reviewer_verdict text,
  add column if not exists reviewer_top_candidates jsonb not null default '[]'::jsonb,
  add column if not exists reviewer_missing_evidence jsonb not null default '[]'::jsonb,
  add column if not exists reviewer_failure_mode_tags text[] not null default '{}'::text[],
  add column if not exists reviewer_rationale_anchors jsonb not null default '[]'::jsonb,
  add column if not exists reviewer_notes text,
  add column if not exists reviewer_completed_at timestamptz;
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'eval_samples_reviewer_verdict_chk'
  ) then
    alter table public.eval_samples
      add constraint eval_samples_reviewer_verdict_chk
      check (
        reviewer_verdict is null
        or reviewer_verdict in ('MATCH', 'MISMATCH', 'INSUFFICIENT')
      );
  end if;
end
$$;
create index if not exists eval_samples_reviewer_verdict_idx
  on public.eval_samples (reviewer_verdict);
create index if not exists eval_samples_reviewer_completed_idx
  on public.eval_samples (reviewer_completed_at desc)
  where reviewer_completed_at is not null;
create index if not exists eval_samples_reviewer_failure_mode_gin_idx
  on public.eval_samples
  using gin (reviewer_failure_mode_tags);
create or replace view public.v_prod_attrib_audit_dashboard_7d as
with recent_runs as (
  select er.id
  from public.eval_runs er
  where er.name like 'prod_attrib_audit_%'
    and er.created_at >= (now() - interval '7 days')
),
recent_samples as (
  select
    es.id,
    es.reviewer_verdict,
    es.reviewer_failure_mode_tags
  from public.eval_samples es
  join recent_runs rr on rr.id = es.eval_run_id
),
verdict_counts as (
  select
    count(*) filter (
      where reviewer_verdict in ('MATCH', 'MISMATCH', 'INSUFFICIENT')
    )::int as reviewed_total_7d,
    count(*) filter (
      where reviewer_verdict = 'MISMATCH'
    )::int as mismatch_count_7d,
    count(*) filter (
      where reviewer_verdict = 'INSUFFICIENT'
    )::int as insufficient_count_7d
  from recent_samples
),
top_failure_modes as (
  select
    tag as failure_mode_tag,
    count(*)::int as tag_count
  from recent_samples rs
  cross join lateral unnest(coalesce(rs.reviewer_failure_mode_tags, '{}'::text[])) as tag
  where coalesce(tag, '') <> ''
  group by tag
  order by tag_count desc, failure_mode_tag
  limit 10
),
top_failure_modes_json as (
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'failure_mode_tag', tfm.failure_mode_tag,
          'count', tfm.tag_count
        )
        order by tfm.tag_count desc, tfm.failure_mode_tag
      ),
      '[]'::jsonb
    ) as top_failure_modes
  from top_failure_modes tfm
)
select
  now() as generated_at_utc,
  vc.reviewed_total_7d,
  vc.mismatch_count_7d,
  case
    when vc.reviewed_total_7d > 0 then
      round(vc.mismatch_count_7d::numeric / vc.reviewed_total_7d::numeric, 4)
    else 0::numeric
  end as mismatch_rate_7d,
  vc.insufficient_count_7d,
  case
    when vc.reviewed_total_7d > 0 then
      round(vc.insufficient_count_7d::numeric / vc.reviewed_total_7d::numeric, 4)
    else 0::numeric
  end as insufficient_rate_7d,
  tfmj.top_failure_modes
from verdict_counts vc
cross join top_failure_modes_json tfmj;
comment on view public.v_prod_attrib_audit_dashboard_7d is
'7-day standing audit tile: mismatch/insufficient rates and top failure modes for prod attribution samples.';
