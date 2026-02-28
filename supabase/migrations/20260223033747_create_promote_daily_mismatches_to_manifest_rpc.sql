-- Adds support columns + RPC for auto-promoting daily mismatches to active attribution manifest

-- 1) Track whether a mismatch ledger row has been promoted to a manifest
alter table public.attribution_audit_ledger
  add column if not exists promoted_to_manifest timestamptz;

-- 2) Store source audit_sample_id on manifest items (optional but requested by STRAT)
alter table public.attribution_audit_manifest_items
  add column if not exists promoted_from_audit_sample_id uuid;

-- 3) Basic idempotency on (manifest_id, ledger_id)
create unique index if not exists attribution_audit_manifest_items_manifest_ledger_uidx
  on public.attribution_audit_manifest_items(manifest_id, ledger_id);

-- 4) RPC: promote_daily_mismatches_to_manifest
create or replace function public.promote_daily_mismatches_to_manifest()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manifest_id uuid;
  v_promoted_count int := 0;
  v_skipped_count int := 0;
begin
  select id into v_manifest_id
  from public.attribution_audit_manifest
  where is_active is true
  order by created_at desc
  limit 1;

  if v_manifest_id is null then
    return jsonb_build_object(
      'promoted_count', 0,
      'skipped_count', 0,
      'error', 'no_active_manifest'
    );
  end if;

  with candidates as (
    select
      l.id as ledger_id,
      l.span_id,
      l.failure_mode_bucket,
      l.expected_project_id,
      l.audit_sample_id,
      l.interaction_id
    from public.attribution_audit_ledger l
    where l.verdict = 'MISMATCH'
      and l.promoted_to_manifest is null
      and (l.interaction_id is null or l.interaction_id not like 'cll_SHADOW_%')
      and l.span_id is not null
  ),
  to_promote as (
    select c.*
    from candidates c
    where not exists (
      select 1
      from public.attribution_audit_manifest_items mi
      join public.attribution_audit_ledger l2 on l2.id = mi.ledger_id
      where mi.manifest_id = v_manifest_id
        and l2.span_id = c.span_id
        and coalesce(l2.failure_mode_bucket, '') = coalesce(c.failure_mode_bucket, '')
        and coalesce(l2.expected_project_id::text, '') = coalesce(c.expected_project_id::text, '')
    )
  ),
  inserted as (
    insert into public.attribution_audit_manifest_items (
      manifest_id,
      ledger_id,
      promoted_from_audit_sample_id,
      notes,
      added_by
    )
    select
      v_manifest_id,
      tp.ledger_id,
      tp.audit_sample_id,
      'auto_daily_mismatch',
      'system'
    from to_promote tp
    on conflict (manifest_id, ledger_id) do nothing
    returning ledger_id
  ),
  updated as (
    update public.attribution_audit_ledger l
    set promoted_to_manifest = now()
    where l.id in (select ledger_id from inserted)
    returning l.id
  )
  select count(*) into v_promoted_count from updated;

  -- Skipped = eligible candidates - actually promoted
  select (select count(*) from candidates) - v_promoted_count into v_skipped_count;

  return jsonb_build_object(
    'manifest_id', v_manifest_id,
    'promoted_count', v_promoted_count,
    'skipped_count', v_skipped_count
  );
end;
$$;

-- Lock down execution to service_role
revoke all on function public.promote_daily_mismatches_to_manifest() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.promote_daily_mismatches_to_manifest() to service_role;
  end if;
end $$;
;
