-- Auto-review resolver:
-- - Auto-resolve pending review_queue rows where candidate_confidence >= 0.85
-- - Auto-dismiss pending review_queue rows where candidate_confidence < 0.20
-- - Leave middle band (0.20-0.85) for human review
-- - Log all auto decisions in review_audit

begin;

create table if not exists public.review_audit (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null,
  review_queue_id uuid not null references public.review_queue(id) on delete cascade,
  span_id uuid null,
  interaction_id text null,
  candidate_project_id uuid null,
  candidate_confidence numeric null,
  audit_action text not null check (audit_action in ('auto_resolved', 'auto_dismissed', 'auto_resolve_skipped')),
  reason text not null check (reason in (
    'auto_high_confidence',
    'auto_low_confidence',
    'missing_candidate_project',
    'resolver_error',
    'already_terminal'
  )),
  actor text not null,
  details jsonb null,
  created_at timestamptz not null default now()
);

create index if not exists idx_review_audit_created_at
  on public.review_audit(created_at desc);

create index if not exists idx_review_audit_run_id
  on public.review_audit(run_id);

create index if not exists idx_review_audit_review_queue_id
  on public.review_audit(review_queue_id);

create index if not exists idx_review_audit_reason_action
  on public.review_audit(reason, audit_action);

comment on table public.review_audit is
  'Audit log for automated review_queue decisions (auto resolve/dismiss/skip).';

comment on column public.review_audit.reason is
  'Decision reason: auto_high_confidence or auto_low_confidence; skipped reasons track why no write occurred.';

create or replace function public.run_auto_review_resolver(
  p_high_conf numeric default 0.85,
  p_low_conf numeric default 0.20,
  p_limit integer default 500,
  p_actor text default 'system:auto_review_resolver',
  p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started_at timestamptz := clock_timestamp();
  v_run_id uuid := gen_random_uuid();
  v_limit integer := greatest(coalesce(p_limit, 500), 1);

  v_total_candidates integer := 0;
  v_high_candidates integer := 0;
  v_low_candidates integer := 0;
  v_mid_candidates integer := 0;

  v_high_resolved integer := 0;
  v_high_skipped integer := 0;
  v_low_dismissed integer := 0;

  v_high_sample jsonb := '[]'::jsonb;
  v_low_sample jsonb := '[]'::jsonb;

  v_row record;
  v_rpc_result jsonb;
begin
  if p_high_conf is null or p_low_conf is null then
    raise exception 'invalid_thresholds: thresholds cannot be null';
  end if;
  if p_low_conf < 0 or p_high_conf > 1 or p_low_conf >= p_high_conf then
    raise exception 'invalid_thresholds: require 0 <= low < high <= 1';
  end if;

  create temp table tmp_auto_review_candidates on commit drop as
  select
    rq.id as review_queue_id,
    rq.span_id,
    rq.interaction_id::text as interaction_id,
    rq.created_at,
    case
      when coalesce(jsonb_typeof(rq.context_payload->'candidate_project_id'), 'null') in ('string')
           and (rq.context_payload->>'candidate_project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (rq.context_payload->>'candidate_project_id')::uuid
      else null
    end as candidate_project_id,
    case
      when coalesce(jsonb_typeof(rq.context_payload->'candidate_confidence'), 'null') in ('string', 'number')
           and (rq.context_payload->>'candidate_confidence') ~ '^[-+]?[0-9]*\\.?[0-9]+$'
      then (rq.context_payload->>'candidate_confidence')::numeric
      else null
    end as candidate_confidence
  from public.review_queue rq
  where rq.status = 'pending'
  order by rq.created_at asc
  limit v_limit;

  select count(*) into v_total_candidates from tmp_auto_review_candidates;
  select count(*)
  into v_high_candidates
  from tmp_auto_review_candidates
  where candidate_confidence is not null
    and candidate_confidence >= p_high_conf
    and candidate_confidence <= 1;
  select count(*)
  into v_low_candidates
  from tmp_auto_review_candidates
  where candidate_confidence is not null
    and candidate_confidence >= 0
    and candidate_confidence < p_low_conf;
  v_mid_candidates := greatest(v_total_candidates - v_high_candidates - v_low_candidates, 0);

  if p_dry_run then
    select coalesce(jsonb_agg(x.review_queue_id), '[]'::jsonb)
    into v_high_sample
    from (
      select review_queue_id
      from tmp_auto_review_candidates
      where candidate_confidence is not null
        and candidate_confidence >= p_high_conf
        and candidate_confidence <= 1
      order by created_at asc
      limit 20
    ) x;

    select coalesce(jsonb_agg(x.review_queue_id), '[]'::jsonb)
    into v_low_sample
    from (
      select review_queue_id
      from tmp_auto_review_candidates
      where candidate_confidence is not null
        and candidate_confidence >= 0
        and candidate_confidence < p_low_conf
      order by created_at asc
      limit 20
    ) x;

    return jsonb_build_object(
      'ok', true,
      'dry_run', true,
      'run_id', v_run_id,
      'thresholds', jsonb_build_object('high', p_high_conf, 'low', p_low_conf),
      'scanned', v_total_candidates,
      'bands', jsonb_build_object(
        'high_auto_resolve_candidates', v_high_candidates,
        'low_auto_dismiss_candidates', v_low_candidates,
        'human_review_candidates', v_mid_candidates
      ),
      'sample', jsonb_build_object(
        'high_review_queue_ids', v_high_sample,
        'low_review_queue_ids', v_low_sample
      ),
      'actor', p_actor,
      'ms', floor(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)
    );
  end if;

  create temp table tmp_low_dismissed (
    review_queue_id uuid,
    span_id uuid,
    interaction_id text,
    candidate_project_id uuid,
    candidate_confidence numeric
  ) on commit drop;

  with updated as (
    update public.review_queue rq
    set
      status = 'dismissed',
      resolved_at = now(),
      resolved_by = p_actor,
      resolution_action = 'auto_dismiss',
      resolution_notes = coalesce(rq.resolution_notes || ' | ', '') || 'auto_low_confidence'
    from tmp_auto_review_candidates c
    where rq.id = c.review_queue_id
      and rq.status = 'pending'
      and c.candidate_confidence is not null
      and c.candidate_confidence >= 0
      and c.candidate_confidence < p_low_conf
    returning
      rq.id as review_queue_id,
      rq.span_id,
      rq.interaction_id::text as interaction_id
  )
  insert into tmp_low_dismissed (
    review_queue_id,
    span_id,
    interaction_id,
    candidate_project_id,
    candidate_confidence
  )
  select
    u.review_queue_id,
    u.span_id,
    u.interaction_id,
    c.candidate_project_id,
    c.candidate_confidence
  from updated u
  join tmp_auto_review_candidates c
    on c.review_queue_id = u.review_queue_id;

  get diagnostics v_low_dismissed = row_count;

  insert into public.review_audit (
    run_id,
    review_queue_id,
    span_id,
    interaction_id,
    candidate_project_id,
    candidate_confidence,
    audit_action,
    reason,
    actor,
    details
  )
  select
    v_run_id,
    d.review_queue_id,
    d.span_id,
    d.interaction_id,
    d.candidate_project_id,
    d.candidate_confidence,
    'auto_dismissed',
    'auto_low_confidence',
    p_actor,
    jsonb_build_object(
      'threshold_low', p_low_conf,
      'source', 'run_auto_review_resolver'
    )
  from tmp_low_dismissed d;

  for v_row in
    select
      c.review_queue_id,
      c.span_id,
      c.interaction_id,
      c.candidate_project_id,
      c.candidate_confidence
    from tmp_auto_review_candidates c
    where c.candidate_confidence is not null
      and c.candidate_confidence >= p_high_conf
      and c.candidate_confidence <= 1
    order by c.created_at asc
  loop
    if v_row.candidate_project_id is null then
      v_high_skipped := v_high_skipped + 1;
      insert into public.review_audit (
        run_id,
        review_queue_id,
        span_id,
        interaction_id,
        candidate_project_id,
        candidate_confidence,
        audit_action,
        reason,
        actor,
        details
      ) values (
        v_run_id,
        v_row.review_queue_id,
        v_row.span_id,
        v_row.interaction_id,
        null,
        v_row.candidate_confidence,
        'auto_resolve_skipped',
        'missing_candidate_project',
        p_actor,
        jsonb_build_object(
          'threshold_high', p_high_conf,
          'source', 'run_auto_review_resolver'
        )
      );
      continue;
    end if;

    begin
      select public.resolve_review_item(
        v_row.review_queue_id,
        v_row.candidate_project_id,
        'auto_high_confidence',
        p_actor
      )
      into v_rpc_result;

      if coalesce(v_rpc_result->>'ok', 'false') = 'true' then
        if coalesce(v_rpc_result->>'was_already_resolved', 'false') = 'true' then
          v_high_skipped := v_high_skipped + 1;
          insert into public.review_audit (
            run_id,
            review_queue_id,
            span_id,
            interaction_id,
            candidate_project_id,
            candidate_confidence,
            audit_action,
            reason,
            actor,
            details
          ) values (
            v_run_id,
            v_row.review_queue_id,
            v_row.span_id,
            v_row.interaction_id,
            v_row.candidate_project_id,
            v_row.candidate_confidence,
            'auto_resolve_skipped',
            'already_terminal',
            p_actor,
            coalesce(v_rpc_result, '{}'::jsonb)
          );
        else
          v_high_resolved := v_high_resolved + 1;
          insert into public.review_audit (
            run_id,
            review_queue_id,
            span_id,
            interaction_id,
            candidate_project_id,
            candidate_confidence,
            audit_action,
            reason,
            actor,
            details
          ) values (
            v_run_id,
            v_row.review_queue_id,
            v_row.span_id,
            v_row.interaction_id,
            v_row.candidate_project_id,
            v_row.candidate_confidence,
            'auto_resolved',
            'auto_high_confidence',
            p_actor,
            coalesce(v_rpc_result, '{}'::jsonb)
          );
        end if;
      else
        v_high_skipped := v_high_skipped + 1;
        insert into public.review_audit (
          run_id,
          review_queue_id,
          span_id,
          interaction_id,
          candidate_project_id,
          candidate_confidence,
          audit_action,
          reason,
          actor,
          details
        ) values (
          v_run_id,
          v_row.review_queue_id,
          v_row.span_id,
          v_row.interaction_id,
          v_row.candidate_project_id,
          v_row.candidate_confidence,
          'auto_resolve_skipped',
          'resolver_error',
          p_actor,
          coalesce(v_rpc_result, '{}'::jsonb)
        );
      end if;
    exception
      when others then
        v_high_skipped := v_high_skipped + 1;
        insert into public.review_audit (
          run_id,
          review_queue_id,
          span_id,
          interaction_id,
          candidate_project_id,
          candidate_confidence,
          audit_action,
          reason,
          actor,
          details
        ) values (
          v_run_id,
          v_row.review_queue_id,
          v_row.span_id,
          v_row.interaction_id,
          v_row.candidate_project_id,
          v_row.candidate_confidence,
          'auto_resolve_skipped',
          'resolver_error',
          p_actor,
          jsonb_build_object(
            'error', sqlerrm,
            'source', 'run_auto_review_resolver'
          )
        );
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'dry_run', false,
    'run_id', v_run_id,
    'thresholds', jsonb_build_object('high', p_high_conf, 'low', p_low_conf),
    'scanned', v_total_candidates,
    'bands', jsonb_build_object(
      'high_auto_resolve_candidates', v_high_candidates,
      'low_auto_dismiss_candidates', v_low_candidates,
      'human_review_candidates', v_mid_candidates
    ),
    'applied', jsonb_build_object(
      'high_auto_resolved', v_high_resolved,
      'high_skipped', v_high_skipped,
      'low_auto_dismissed', v_low_dismissed
    ),
    'actor', p_actor,
    'ms', floor(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)
  );
end;
$$;

comment on function public.run_auto_review_resolver is
  'Auto-resolves/dismisses pending review_queue rows by confidence thresholds. Logs all decisions to review_audit.';

grant execute on function public.run_auto_review_resolver(numeric, numeric, integer, text, boolean) to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'auto_review_resolver_daily'
      ) then
        perform cron.schedule(
          'auto_review_resolver_daily',
          '15 13 * * *',
          $cron$select public.run_auto_review_resolver(0.85, 0.20, 500, 'system:auto_review_resolver_cron', false);$cron$
        );
      end if;
    exception
      when others then
        raise notice 'auto_review_resolver cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
