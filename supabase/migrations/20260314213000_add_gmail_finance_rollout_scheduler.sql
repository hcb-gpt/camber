-- Mechanical Gmail finance rollout scheduler:
-- 1) mailbox-specific profile_set seeds for the reference Zack mailbox
-- 2) rollout schedule registry
-- 3) manual/cron dispatcher helpers for shadow and live runs

insert into public.gmail_query_profiles (
  profile_set,
  profile_slug,
  priority,
  gmail_query,
  class_hint,
  active,
  mailbox_scope,
  label_mirror_name,
  effective_after_date,
  notes
)
select
  'finance_zack_v1' as profile_set,
  profile_slug,
  priority,
  gmail_query,
  class_hint,
  active,
  'zack@heartwoodcustombuilders.com' as mailbox_scope,
  label_mirror_name,
  effective_after_date,
  coalesce(notes, '{}'::jsonb) || jsonb_build_object(
    'seed_clone_of', 'finance_v1',
    'rollout_wave', 'reference_mailbox'
  ) as notes
from public.gmail_query_profiles
where profile_set = 'finance_v1'
on conflict (profile_set, profile_slug) do update
  set priority = excluded.priority,
      gmail_query = excluded.gmail_query,
      class_hint = excluded.class_hint,
      active = excluded.active,
      mailbox_scope = excluded.mailbox_scope,
      label_mirror_name = excluded.label_mirror_name,
      effective_after_date = excluded.effective_after_date,
      notes = excluded.notes,
      updated_at = now();

create table if not exists public.gmail_financial_pipeline_schedules (
  id uuid primary key default gen_random_uuid(),
  schedule_slug text not null,
  profile_set text not null,
  pipeline_key text not null,
  mailbox_scope text not null,
  candidate_limit integer not null default 100
    check (candidate_limit between 1 and 300),
  max_targets integer not null default 40
    check (max_targets between 1 and 150),
  overlap_days integer not null default 2
    check (overlap_days between 0 and 14),
  cron_enabled boolean not null default false,
  write_enabled boolean not null default false,
  active boolean not null default true,
  notes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists gmail_financial_pipeline_schedules_slug_uq
  on public.gmail_financial_pipeline_schedules (schedule_slug);

create unique index if not exists gmail_financial_pipeline_schedules_pipeline_key_uq
  on public.gmail_financial_pipeline_schedules (pipeline_key);

create index if not exists gmail_financial_pipeline_schedules_active_cron_idx
  on public.gmail_financial_pipeline_schedules (active, cron_enabled, schedule_slug);

create index if not exists gmail_financial_pipeline_schedules_profile_set_idx
  on public.gmail_financial_pipeline_schedules (profile_set, active, mailbox_scope);

comment on table public.gmail_financial_pipeline_schedules is
  'Mailbox-scoped rollout registry for the mechanical Gmail finance workflow. One row = one mailbox-specific schedule contract.';

alter table public.gmail_financial_pipeline_schedules enable row level security;

drop policy if exists "service_role_all_gmail_financial_pipeline_schedules" on public.gmail_financial_pipeline_schedules;
create policy "service_role_all_gmail_financial_pipeline_schedules"
  on public.gmail_financial_pipeline_schedules
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

grant select, insert, update, delete on table public.gmail_financial_pipeline_schedules to service_role;

insert into public.gmail_financial_pipeline_schedules (
  schedule_slug,
  profile_set,
  pipeline_key,
  mailbox_scope,
  candidate_limit,
  max_targets,
  overlap_days,
  cron_enabled,
  write_enabled,
  active,
  notes
)
values (
  'finance_zack_prod',
  'finance_zack_v1',
  'finance_zack_prod',
  'zack@heartwoodcustombuilders.com',
  100,
  40,
  2,
  false,
  false,
  true,
  jsonb_build_object(
    'seed_source', 'mechanical_rollout_v1',
    'wave', 'reference_mailbox',
    'operator_state', 'shadow_ready'
  )
)
on conflict (schedule_slug) do update
  set profile_set = excluded.profile_set,
      pipeline_key = excluded.pipeline_key,
      mailbox_scope = excluded.mailbox_scope,
      candidate_limit = excluded.candidate_limit,
      max_targets = excluded.max_targets,
      overlap_days = excluded.overlap_days,
      cron_enabled = excluded.cron_enabled,
      write_enabled = excluded.write_enabled,
      active = excluded.active,
      notes = excluded.notes,
      updated_at = now();

create or replace function public.fire_gmail_financial_pipeline_schedule(
  p_schedule_slug text,
  p_dry_run boolean default null,
  p_bootstrap_lookback_days integer default null,
  p_pipeline_key_override text default null,
  p_run_mode text default null,
  p_candidate_limit integer default null,
  p_max_targets integer default null,
  p_overlap_days integer default null,
  p_review_only boolean default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_request_id bigint;
  v_has_pg_net boolean;
  v_has_vault boolean;
  v_run_mode text;
  v_schedule public.gmail_financial_pipeline_schedules%rowtype;
begin
  select *
    into v_schedule
  from public.gmail_financial_pipeline_schedules
  where schedule_slug = p_schedule_slug
    and active = true
  limit 1;

  if not found then
    raise exception 'schedule_not_found_or_inactive:%', p_schedule_slug;
  end if;

  v_run_mode := coalesce(nullif(trim(coalesce(p_run_mode, '')), ''), 'full');
  if v_run_mode not in ('retrieve_only', 'classify_only', 'extract_only', 'full') then
    raise exception 'invalid_run_mode:%', v_run_mode;
  end if;

  if p_bootstrap_lookback_days is not null and (p_bootstrap_lookback_days < 1 or p_bootstrap_lookback_days > 365) then
    raise exception 'invalid_bootstrap_lookback_days:%', p_bootstrap_lookback_days;
  end if;

  if p_candidate_limit is not null and (p_candidate_limit < 1 or p_candidate_limit > 300) then
    raise exception 'invalid_candidate_limit:%', p_candidate_limit;
  end if;

  if p_max_targets is not null and (p_max_targets < 1 or p_max_targets > 150) then
    raise exception 'invalid_max_targets:%', p_max_targets;
  end if;

  if p_overlap_days is not null and (p_overlap_days < 0 or p_overlap_days > 14) then
    raise exception 'invalid_overlap_days:%', p_overlap_days;
  end if;

  select exists (select 1 from pg_extension where extname = 'pg_net') into v_has_pg_net;
  if not v_has_pg_net then
    raise notice 'fire_gmail_financial_pipeline_schedule: pg_net extension missing; skipping';
    return -2;
  end if;

  select exists (select 1 from pg_extension where extname = 'supabase_vault') into v_has_vault;

  v_base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://rjhdwidddtfetbwqolof.supabase.co'
  );
  v_base_url := rtrim(v_base_url, '/');

  v_anon_key := current_setting('app.settings.anon_key', true);
  if v_anon_key is null and v_has_vault then
    select decrypted_secret into v_anon_key
    from vault.decrypted_secrets
    where name = 'supabase_anon_key'
    limit 1;
  end if;

  v_edge_secret := current_setting('app.settings.edge_shared_secret', true);
  if v_edge_secret is null and v_has_vault then
    select decrypted_secret into v_edge_secret
    from vault.decrypted_secrets
    where name = 'edge_shared_secret'
    limit 1;
  end if;

  if v_anon_key is null or v_edge_secret is null then
    if not v_has_vault then
      raise notice 'fire_gmail_financial_pipeline_schedule: missing anon_key or edge_secret and supabase_vault not installed; skipping';
    else
      raise notice 'fire_gmail_financial_pipeline_schedule: missing anon_key or edge_secret, skipping';
    end if;
    return -1;
  end if;

  select net.http_post(
    url := v_base_url || '/functions/v1/gmail-financial-pipeline',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      'X-Source', 'gmail-financial-pipeline'
    ),
    body := jsonb_strip_nulls(jsonb_build_object(
      'bootstrap_lookback_days', p_bootstrap_lookback_days,
      'candidate_limit', coalesce(p_candidate_limit, v_schedule.candidate_limit),
      'dry_run', coalesce(p_dry_run, not v_schedule.write_enabled),
      'max_targets', coalesce(p_max_targets, v_schedule.max_targets),
      'overlap_days', coalesce(p_overlap_days, v_schedule.overlap_days),
      'pipeline_key', coalesce(nullif(trim(coalesce(p_pipeline_key_override, '')), ''), v_schedule.pipeline_key),
      'profile_set', v_schedule.profile_set,
      'review_only', coalesce(p_review_only, false),
      'run_mode', v_run_mode,
      'schedule_slug', v_schedule.schedule_slug
    ))
  ) into v_request_id;

  return v_request_id;
end;
$$;

comment on function public.fire_gmail_financial_pipeline_schedule(
  text,
  boolean,
  integer,
  text,
  text,
  integer,
  integer,
  integer,
  boolean
) is
  'Manual/automated rollout helper for mailbox-specific Gmail finance schedule rows. Supports dry-run shadow, bounded backfill, and live writes through a single schedule contract.';

revoke execute on function public.fire_gmail_financial_pipeline_schedule(
  text,
  boolean,
  integer,
  text,
  text,
  integer,
  integer,
  integer,
  boolean
) from public;
grant execute on function public.fire_gmail_financial_pipeline_schedule(
  text,
  boolean,
  integer,
  text,
  text,
  integer,
  integer,
  integer,
  boolean
) to service_role;

create or replace function public.cron_fire_gmail_financial_pipeline_dispatcher()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_request_id bigint;
  row record;
begin
  for row in
    select schedule_slug, write_enabled
    from public.gmail_financial_pipeline_schedules
    where active = true
      and cron_enabled = true
    order by schedule_slug
  loop
    begin
      v_request_id := public.fire_gmail_financial_pipeline_schedule(
        row.schedule_slug,
        not row.write_enabled,
        null,
        null,
        'full',
        null,
        null,
        null,
        false
      );

      v_result := v_result || jsonb_build_array(jsonb_build_object(
        'dry_run', not row.write_enabled,
        'request_id', v_request_id,
        'schedule_slug', row.schedule_slug
      ));
    exception
      when others then
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'error', SQLERRM,
          'schedule_slug', row.schedule_slug
        ));
    end;
  end loop;

  return v_result;
end;
$$;

comment on function public.cron_fire_gmail_financial_pipeline_dispatcher() is
  'Dispatcher for mailbox-scoped Gmail finance schedule rows. Intended for steady-state cron after manual guarded rollout passes.';

revoke execute on function public.cron_fire_gmail_financial_pipeline_dispatcher() from public;
grant execute on function public.cron_fire_gmail_financial_pipeline_dispatcher() to service_role;
