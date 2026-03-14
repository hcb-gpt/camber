-- Gmail financial pipeline: canonical Gmail receipt lane + scheduled edge trigger.
-- Goal:
-- 1) Periodically scan a Gmail invoice label.
-- 2) Extract vendor / total / job_name / receipt_date / invoice_or_transaction.
-- 3) Persist canonical rows with exact Gmail financial business fields.
-- 4) Deduplicate by vendor_normalized + total + receipt_date.

create table if not exists public.gmail_financial_receipts (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null,
  vendor text not null,
  vendor_normalized text not null,
  total numeric(12,2) not null,
  job_name text,
  project_id uuid references public.projects(id) on delete set null,
  matched_project_alias text,
  receipt_date date not null,
  invoice_or_transaction text,
  source text not null default 'gmail_scrape' check (source = 'gmail_scrape'),
  source_message_ids text[] not null default '{}'::text[],
  source_thread_ids text[] not null default '{}'::text[],
  latest_gmail_internal_date timestamptz,
  gmail_label_id text,
  sample_subject text,
  sample_from text,
  evidence_locator text not null,
  body_excerpt text,
  extraction_confidence numeric(5,4),
  extraction_meta jsonb not null default '{}'::jsonb,
  hit_count integer not null default 1,
  first_seen_at_utc timestamptz not null default now(),
  last_seen_at_utc timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists gmail_financial_receipts_dedupe_key_uq
  on public.gmail_financial_receipts (dedupe_key);
create index if not exists gmail_financial_receipts_receipt_date_idx
  on public.gmail_financial_receipts (receipt_date desc);
create index if not exists gmail_financial_receipts_project_date_idx
  on public.gmail_financial_receipts (project_id, receipt_date desc);
create index if not exists gmail_financial_receipts_vendor_date_idx
  on public.gmail_financial_receipts (vendor_normalized, receipt_date desc);

comment on table public.gmail_financial_receipts is
  'Canonical Gmail financial receipts extracted from invoice emails. Exact business columns for downstream Gandalf-style financial rows; dedupe is vendor+total+receipt_date.';

create table if not exists public.gmail_financial_pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  pipeline_key text not null default 'default',
  label_id text not null,
  gmail_after_date date not null,
  gmail_query text not null,
  max_messages integer not null default 100,
  gmail_result_estimate integer,
  messages_listed integer not null default 0,
  messages_examined integer not null default 0,
  receipts_inserted integer not null default 0,
  duplicates_seen integer not null default 0,
  skipped_missing_amount integer not null default 0,
  skipped_missing_date integer not null default 0,
  skipped_missing_vendor integer not null default 0,
  skipped_other integer not null default 0,
  max_internal_date_ms bigint,
  status text not null default 'running' check (status in ('running', 'ok', 'partial', 'failed', 'dry_run')),
  warnings jsonb not null default '[]'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  started_at_utc timestamptz not null default now(),
  finished_at_utc timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists gmail_financial_pipeline_runs_key_finished_idx
  on public.gmail_financial_pipeline_runs (pipeline_key, finished_at_utc desc nulls last);

comment on table public.gmail_financial_pipeline_runs is
  'Audit log for Gmail financial pipeline invocations: cursor, counts, skips, warnings, and latest Gmail internal date.';

alter table public.gmail_financial_receipts enable row level security;
alter table public.gmail_financial_pipeline_runs enable row level security;

drop policy if exists "service_role_all_gmail_financial_receipts" on public.gmail_financial_receipts;
create policy "service_role_all_gmail_financial_receipts"
  on public.gmail_financial_receipts
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

drop policy if exists "service_role_all_gmail_financial_pipeline_runs" on public.gmail_financial_pipeline_runs;
create policy "service_role_all_gmail_financial_pipeline_runs"
  on public.gmail_financial_pipeline_runs
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create or replace function public.gmail_financial_receipt_dedupe_key(
  p_vendor_normalized text,
  p_total numeric,
  p_receipt_date date
)
returns text
language sql
immutable
as $$
  select md5(
    concat_ws(
      '|',
      coalesce(nullif(lower(trim(p_vendor_normalized)), ''), '_'),
      to_char(round(coalesce(p_total, 0)::numeric, 2), 'FM9999999990.00'),
      coalesce(to_char(p_receipt_date, 'YYYY-MM-DD'), '_')
    )
  );
$$;

comment on function public.gmail_financial_receipt_dedupe_key is
  'Deterministic Gmail financial receipt dedupe key: vendor_normalized + total + receipt_date.';

create or replace function public.upsert_gmail_financial_receipt(
  p_receipt jsonb
)
returns table (
  receipt_id uuid,
  dedupe_key text,
  is_duplicate boolean,
  hit_count integer,
  first_seen_at_utc timestamptz,
  last_seen_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vendor text;
  v_vendor_normalized text;
  v_total numeric(12,2);
  v_job_name text;
  v_project_id uuid;
  v_matched_project_alias text;
  v_receipt_date date;
  v_invoice_or_transaction text;
  v_source text;
  v_source_message_ids text[] := '{}'::text[];
  v_source_thread_ids text[] := '{}'::text[];
  v_latest_gmail_internal_date timestamptz;
  v_gmail_label_id text;
  v_sample_subject text;
  v_sample_from text;
  v_evidence_locator text;
  v_body_excerpt text;
  v_extraction_confidence numeric(5,4);
  v_extraction_meta jsonb := '{}'::jsonb;
  v_dedupe_key text;
  v_receipt_id uuid;
  v_hit_count integer;
  v_first_seen timestamptz;
  v_last_seen timestamptz;
begin
  if p_receipt is null or jsonb_typeof(p_receipt) <> 'object' then
    raise exception 'invalid_receipt: p_receipt must be a json object';
  end if;

  v_vendor := nullif(trim(coalesce(p_receipt->>'vendor', '')), '');
  if v_vendor is null then
    raise exception 'invalid_receipt: vendor is required';
  end if;

  v_vendor_normalized := nullif(trim(coalesce(p_receipt->>'vendor_normalized', '')), '');
  if v_vendor_normalized is null then
    raise exception 'invalid_receipt: vendor_normalized is required';
  end if;

  if coalesce(p_receipt->>'total', '') !~ '^-?[0-9]+(\.[0-9]+)?$' then
    raise exception 'invalid_receipt: total must be numeric';
  end if;
  v_total := round((p_receipt->>'total')::numeric, 2);

  v_receipt_date := nullif(trim(coalesce(p_receipt->>'receipt_date', '')), '')::date;
  if v_receipt_date is null then
    raise exception 'invalid_receipt: receipt_date is required';
  end if;

  v_source := lower(trim(coalesce(p_receipt->>'source', 'gmail_scrape')));
  if v_source <> 'gmail_scrape' then
    raise exception 'invalid_receipt: source must be gmail_scrape';
  end if;

  if jsonb_typeof(p_receipt->'source_message_ids') <> 'array' then
    raise exception 'invalid_receipt: source_message_ids must be a non-empty array';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}'::text[])
    into v_source_message_ids
  from (
    select nullif(trim(value), '') as x
    from jsonb_array_elements_text(p_receipt->'source_message_ids')
  ) rows
  where x is not null;
  if coalesce(array_length(v_source_message_ids, 1), 0) = 0 then
    raise exception 'invalid_receipt: source_message_ids must be a non-empty array';
  end if;

  if p_receipt ? 'source_thread_ids' then
    if jsonb_typeof(p_receipt->'source_thread_ids') <> 'array' then
      raise exception 'invalid_receipt: source_thread_ids must be an array when provided';
    end if;
    select coalesce(array_agg(distinct x order by x), '{}'::text[])
      into v_source_thread_ids
    from (
      select nullif(trim(value), '') as x
      from jsonb_array_elements_text(p_receipt->'source_thread_ids')
    ) rows
    where x is not null;
  end if;

  v_job_name := nullif(trim(coalesce(p_receipt->>'job_name', '')), '');
  v_matched_project_alias := nullif(trim(coalesce(p_receipt->>'matched_project_alias', '')), '');
  v_invoice_or_transaction := nullif(trim(coalesce(p_receipt->>'invoice_or_transaction', '')), '');
  v_gmail_label_id := nullif(trim(coalesce(p_receipt->>'gmail_label_id', '')), '');
  v_sample_subject := nullif(trim(coalesce(p_receipt->>'sample_subject', '')), '');
  v_sample_from := nullif(trim(coalesce(p_receipt->>'sample_from', '')), '');
  v_evidence_locator := nullif(trim(coalesce(p_receipt->>'evidence_locator', '')), '');
  v_body_excerpt := nullif(trim(coalesce(p_receipt->>'body_excerpt', '')), '');
  if v_evidence_locator is null then
    raise exception 'invalid_receipt: evidence_locator is required';
  end if;

  if p_receipt ? 'project_id' and coalesce(p_receipt->>'project_id', '') <> '' then
    if p_receipt->>'project_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'invalid_receipt: project_id must be uuid when provided';
    end if;
    v_project_id := (p_receipt->>'project_id')::uuid;
  end if;

  if p_receipt ? 'latest_gmail_internal_date' and coalesce(p_receipt->>'latest_gmail_internal_date', '') <> '' then
    v_latest_gmail_internal_date := (p_receipt->>'latest_gmail_internal_date')::timestamptz;
  end if;

  if p_receipt ? 'extraction_confidence' and coalesce(p_receipt->>'extraction_confidence', '') <> '' then
    if p_receipt->>'extraction_confidence' !~ '^-?[0-9]+(\.[0-9]+)?$' then
      raise exception 'invalid_receipt: extraction_confidence must be numeric when provided';
    end if;
    v_extraction_confidence := round((p_receipt->>'extraction_confidence')::numeric, 4);
  end if;

  if p_receipt ? 'extraction_meta' then
    if jsonb_typeof(p_receipt->'extraction_meta') <> 'object' then
      raise exception 'invalid_receipt: extraction_meta must be an object when provided';
    end if;
    v_extraction_meta := p_receipt->'extraction_meta';
  end if;

  v_dedupe_key := public.gmail_financial_receipt_dedupe_key(
    v_vendor_normalized,
    v_total,
    v_receipt_date
  );

  insert into public.gmail_financial_receipts (
    dedupe_key,
    vendor,
    vendor_normalized,
    total,
    job_name,
    project_id,
    matched_project_alias,
    receipt_date,
    invoice_or_transaction,
    source,
    source_message_ids,
    source_thread_ids,
    latest_gmail_internal_date,
    gmail_label_id,
    sample_subject,
    sample_from,
    evidence_locator,
    body_excerpt,
    extraction_confidence,
    extraction_meta
  )
  values (
    v_dedupe_key,
    v_vendor,
    v_vendor_normalized,
    v_total,
    v_job_name,
    v_project_id,
    v_matched_project_alias,
    v_receipt_date,
    v_invoice_or_transaction,
    v_source,
    v_source_message_ids,
    v_source_thread_ids,
    v_latest_gmail_internal_date,
    v_gmail_label_id,
    v_sample_subject,
    v_sample_from,
    v_evidence_locator,
    v_body_excerpt,
    v_extraction_confidence,
    v_extraction_meta
  )
  on conflict (dedupe_key) do update
    set hit_count = public.gmail_financial_receipts.hit_count + 1,
        vendor = excluded.vendor,
        vendor_normalized = excluded.vendor_normalized,
        total = excluded.total,
        job_name = coalesce(excluded.job_name, public.gmail_financial_receipts.job_name),
        project_id = coalesce(excluded.project_id, public.gmail_financial_receipts.project_id),
        matched_project_alias = coalesce(excluded.matched_project_alias, public.gmail_financial_receipts.matched_project_alias),
        invoice_or_transaction = coalesce(excluded.invoice_or_transaction, public.gmail_financial_receipts.invoice_or_transaction),
        source_message_ids = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.gmail_financial_receipts.source_message_ids, '{}'::text[])
            || coalesce(excluded.source_message_ids, '{}'::text[])
          ) as u(x)
          where nullif(trim(u.x), '') is not null
        ),
        source_thread_ids = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.gmail_financial_receipts.source_thread_ids, '{}'::text[])
            || coalesce(excluded.source_thread_ids, '{}'::text[])
          ) as u(x)
          where nullif(trim(u.x), '') is not null
        ),
        latest_gmail_internal_date = greatest(
          coalesce(public.gmail_financial_receipts.latest_gmail_internal_date, excluded.latest_gmail_internal_date),
          coalesce(excluded.latest_gmail_internal_date, public.gmail_financial_receipts.latest_gmail_internal_date)
        ),
        gmail_label_id = coalesce(excluded.gmail_label_id, public.gmail_financial_receipts.gmail_label_id),
        sample_subject = coalesce(excluded.sample_subject, public.gmail_financial_receipts.sample_subject),
        sample_from = coalesce(excluded.sample_from, public.gmail_financial_receipts.sample_from),
        evidence_locator = excluded.evidence_locator,
        body_excerpt = coalesce(excluded.body_excerpt, public.gmail_financial_receipts.body_excerpt),
        extraction_confidence = coalesce(excluded.extraction_confidence, public.gmail_financial_receipts.extraction_confidence),
        extraction_meta = coalesce(public.gmail_financial_receipts.extraction_meta, '{}'::jsonb)
          || coalesce(excluded.extraction_meta, '{}'::jsonb),
        last_seen_at_utc = now(),
        updated_at = now()
  returning
    public.gmail_financial_receipts.id,
    public.gmail_financial_receipts.hit_count,
    public.gmail_financial_receipts.first_seen_at_utc,
    public.gmail_financial_receipts.last_seen_at_utc
  into v_receipt_id, v_hit_count, v_first_seen, v_last_seen;

  return query
  select
    v_receipt_id,
    v_dedupe_key,
    (v_hit_count > 1) as is_duplicate,
    v_hit_count,
    v_first_seen,
    v_last_seen;
end;
$$;

comment on function public.upsert_gmail_financial_receipt(jsonb) is
  'Atomic Gmail financial receipt upsert. Enforces canonical business fields and deduplicates by vendor_normalized + total + receipt_date.';

revoke execute on function public.upsert_gmail_financial_receipt(jsonb) from public;
grant execute on function public.upsert_gmail_financial_receipt(jsonb) to service_role;

create or replace view public.v_gmail_financial_receipts_gandalf_export as
select
  r.id,
  r.vendor,
  r.total,
  coalesce(r.job_name, p.name) as job_name,
  r.receipt_date,
  r.invoice_or_transaction,
  r.source,
  r.project_id,
  r.matched_project_alias,
  r.dedupe_key,
  r.hit_count,
  r.source_message_ids,
  r.source_thread_ids,
  r.evidence_locator,
  r.first_seen_at_utc,
  r.last_seen_at_utc
from public.gmail_financial_receipts r
left join public.projects p
  on p.id = r.project_id;

comment on view public.v_gmail_financial_receipts_gandalf_export is
  'Gandalf-shaped export view for Gmail financial receipts. Core fields: vendor,total,job_name,receipt_date,invoice_or_transaction,source.';

create or replace function public.cron_fire_gmail_financial_pipeline()
returns bigint
language plpgsql
security definer
as $$
declare
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_label_id text;
  v_query text;
  v_request_id bigint;
  v_has_pg_net boolean;
  v_has_vault boolean;
begin
  select exists (select 1 from pg_extension where extname = 'pg_net') into v_has_pg_net;
  if not v_has_pg_net then
    raise notice 'cron_fire_gmail_financial_pipeline: pg_net extension missing; skipping';
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

  v_label_id := coalesce(
    nullif(current_setting('app.settings.gmail_financial_label_id', true), ''),
    'Label_1920211984977558907'
  );
  v_query := coalesce(current_setting('app.settings.gmail_financial_query', true), '');

  if v_anon_key is null or v_edge_secret is null then
    if not v_has_vault then
      raise notice 'cron_fire_gmail_financial_pipeline: missing anon_key or edge_secret and supabase_vault not installed; skipping';
    else
      raise notice 'cron_fire_gmail_financial_pipeline: missing anon_key or edge_secret, skipping';
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
    body := jsonb_build_object(
      'dry_run', false,
      'label_id', v_label_id,
      'max_messages', 100,
      'overlap_days', 2,
      'query', v_query
    )
  ) into v_request_id;

  return v_request_id;
end;
$$;

comment on function public.cron_fire_gmail_financial_pipeline() is
  'pg_net wrapper: invokes gmail-financial-pipeline edge function every 15 minutes using configured Gmail label + query.';

revoke execute on function public.cron_fire_gmail_financial_pipeline() from public;
grant execute on function public.cron_fire_gmail_financial_pipeline() to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (select 1 from cron.job where jobname = 'gmail_financial_pipeline_every_15m') then
        perform cron.schedule(
          'gmail_financial_pipeline_every_15m',
          '*/15 * * * *',
          $$select public.cron_fire_gmail_financial_pipeline();$$
        );
      end if;
    exception
      when others then
        raise notice 'gmail_financial_pipeline cron registration skipped: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron extension missing; gmail_financial_pipeline_every_15m not scheduled';
  end if;
end;
$do$;
