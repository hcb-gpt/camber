-- P4: training data export cron (07:00 UTC daily) + snapshot storage table
-- Source view: public.v_human_truth_attributions
-- Destination table: public.training_data_snapshots (append-only, one row/day)

begin;

create table if not exists public.training_data_snapshots (
  id uuid primary key default gen_random_uuid(),
  snapshot_date date not null,
  source_view text not null default 'v_human_truth_attributions',
  row_count integer not null,
  holdout_count integer not null default 0,
  correction_count integer not null default 0,
  label_counts jsonb not null default '{}'::jsonb,
  snapshot_rows jsonb not null,
  export_version text not null default 'unknown',
  created_by text not null default 'edge:training-data-export',
  created_at timestamptz not null default now()
);

create unique index if not exists training_data_snapshots_snapshot_date_uq
  on public.training_data_snapshots (snapshot_date);

create index if not exists idx_training_data_snapshots_created_at
  on public.training_data_snapshots (created_at desc);

comment on table public.training_data_snapshots is
  'Daily append-only export snapshots from v_human_truth_attributions for training/eval pipelines.';

comment on column public.training_data_snapshots.snapshot_rows is
  'Raw JSON snapshot payload (SELECT * FROM v_human_truth_attributions at export time).';

-- Enforce append-only behavior (no updates/deletes).
create or replace function public.training_data_snapshots_enforce_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'training_data_snapshots is append-only (% not allowed)', tg_op;
end;
$$;

drop trigger if exists trg_training_data_snapshots_append_only
  on public.training_data_snapshots;

create trigger trg_training_data_snapshots_append_only
before update or delete on public.training_data_snapshots
for each row execute function public.training_data_snapshots_enforce_append_only();

-- pg_net wrapper function: POST to training-data-export edge function
create or replace function public.cron_fire_training_data_export()
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
begin
  v_base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://rjhdwidddtfetbwqolof.supabase.co'
  );
  v_anon_key := coalesce(
    current_setting('app.settings.anon_key', true),
    (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1)
  );
  v_edge_secret := coalesce(
    current_setting('app.settings.edge_shared_secret', true),
    (select decrypted_secret from vault.decrypted_secrets where name = 'edge_shared_secret' limit 1)
  );

  if v_anon_key is null or v_edge_secret is null then
    raise notice 'cron_fire_training_data_export: missing anon_key or edge_secret, skipping';
    return -1;
  end if;

  select net.http_post(
    url := v_base_url || '/functions/v1/training-data-export',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      'X-Source', 'cron'
    ),
    body := '{}'::jsonb
  ) into v_request_id;

  return v_request_id;
end;
$$;

comment on function public.cron_fire_training_data_export() is
  'pg_net wrapper: fires training-data-export edge function. Returns pg_net request_id.';

grant execute on function public.cron_fire_training_data_export() to service_role;

-- Schedule: daily at 07:00 UTC
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'training_data_export_daily_0700_utc'
      ) then
        perform cron.schedule(
          'training_data_export_daily_0700_utc',
          '0 7 * * *',
          $$select public.cron_fire_training_data_export();$$
        );
      end if;
    exception
      when others then
        raise notice 'training_data_export cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
;
