-- Gmail gold-standard financial pipeline:
-- Use Camber vendor/contact intelligence rather than Gmail labels as the primary search surface.

create table if not exists public.vendor_emails (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid references public.contacts(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  vendor_name text not null,
  vendor_name_normalized text not null,
  email text not null,
  relation_type text not null check (relation_type in (
    'vendor_contact',
    'client_invoice',
    'manual_seed',
    'utility',
    'professional'
  )),
  confidence numeric(5,4) not null default 0.8000,
  source text not null,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists vendor_emails_identity_uq
  on public.vendor_emails (
    lower(email),
    vendor_name_normalized,
    coalesce(project_id, '00000000-0000-0000-0000-000000000000'::uuid),
    relation_type
  );
create index if not exists vendor_emails_contact_idx
  on public.vendor_emails (contact_id)
  where contact_id is not null;
create index if not exists vendor_emails_project_idx
  on public.vendor_emails (project_id)
  where project_id is not null;
create index if not exists vendor_emails_email_idx
  on public.vendor_emails (lower(email));

comment on table public.vendor_emails is
  'Canonical Gmail vendor/client email search intelligence for the gold-standard financial scrape lane.';

insert into public.vendor_emails (
  contact_id,
  project_id,
  vendor_name,
  vendor_name_normalized,
  email,
  relation_type,
  confidence,
  source,
  notes
)
select
  c.id,
  pc.project_id,
  coalesce(nullif(trim(c.company), ''), nullif(trim(c.name), '')) as vendor_name,
  trim(
    regexp_replace(
      lower(coalesce(nullif(trim(c.company), ''), nullif(trim(c.name), ''))),
      '[^a-z0-9]+',
      ' ',
      'g'
    )
  ) as vendor_name_normalized,
  lower(trim(c.email)) as email,
  case
    when coalesce(c.contact_type, '') in ('client', 'homeowner') then 'client_invoice'
    when coalesce(c.contact_type, '') = 'government' then 'utility'
    when coalesce(c.contact_type, '') in ('professional', 'supplier') then 'professional'
    else 'vendor_contact'
  end as relation_type,
  case
    when pc.project_id is not null then 0.9500
    else 0.8000
  end as confidence,
  'contacts_seed_20260314' as source,
  c.trade as notes
from public.contacts c
left join public.project_contacts pc
  on pc.contact_id = c.id
 and pc.is_active = true
where nullif(trim(c.email), '') is not null
  and coalesce(nullif(trim(c.company), ''), nullif(trim(c.name), '')) is not null
  and (
    coalesce(c.contact_type, '') in (
      'client',
      'government',
      'homeowner',
      'professional',
      'site_supervisor',
      'subcontractor',
      'supplier',
      'vendor'
    )
    or c.trade is not null
    or c.company is not null
  )
on conflict do nothing;

insert into public.vendor_emails (
  vendor_name,
  vendor_name_normalized,
  email,
  relation_type,
  confidence,
  source,
  notes
)
values
  ('Carter Lumber', 'carter lumber', 'credit@carterlumber.com', 'manual_seed', 0.9900, 'gmail_headers_seed_20260314', 'Known invoice sender'),
  ('Accent Granite', 'accent granite', 'accentgranite@elberton.net', 'manual_seed', 0.9900, 'gmail_headers_seed_20260314', 'Known invoice sender'),
  ('QuickBooks', 'quickbooks', 'quickbooks@notification.intuit.com', 'manual_seed', 0.9500, 'gmail_headers_seed_20260314', 'QuickBooks billing mailer'),
  ('Grounded Siteworks', 'grounded siteworks', 'billing@groundedsiteworks.com', 'manual_seed', 0.9500, 'gmail_headers_seed_20260314', 'Known invoice sender'),
  ('Window Concepts', 'window concepts', 'amy@windowconcepts.com', 'manual_seed', 0.9900, 'gmail_headers_seed_20260314', 'Known vendor contact'),
  ('Fieldstone Center', 'fieldstone center', 'virginiah@fieldstonecenter.com', 'manual_seed', 0.9900, 'gmail_headers_seed_20260314', 'Known professional contact'),
  ('Madison Blueprint', 'madison blueprint', 'orders@madisonblueprint.com', 'manual_seed', 0.9000, 'gmail_headers_seed_20260314', 'Blueprint orders and invoices'),
  ('Oconee County Water', 'oconee county water', 'do-not-reply@oconee.ga.us', 'utility', 0.9900, 'gmail_headers_seed_20260314', 'Utility billing sender'),
  ('Ally Tax / Robyn Holland', 'ally tax robyn holland', 'robyn@allytax.us', 'professional', 0.9900, 'gmail_headers_seed_20260314', 'Tax and bookkeeping sender')
on conflict do nothing;

create or replace view public.v_gmail_search_targets as
with base as (
  select
    ve.id as target_id,
    ve.contact_id,
    ve.project_id,
    p.name as project_name,
    ve.vendor_name,
    ve.vendor_name_normalized,
    lower(trim(ve.email)) as email,
    ve.relation_type,
    ve.confidence,
    ve.source,
    c.name as contact_name,
    c.company,
    c.trade,
    coalesce(c.aliases, '{}'::text[]) as contact_aliases,
    coalesce(c.company_aliases, '{}'::text[]) as company_aliases,
    case
      when ve.relation_type = 'client_invoice' then 'client_outbound'
      else 'vendor_correspondence'
    end as target_type,
    (
      case when ve.project_id is not null then 100 else 0 end +
      case when ve.contact_id is not null then 20 else 0 end +
      case when ve.relation_type = 'manual_seed' then 10 else 0 end +
      floor(coalesce(ve.confidence, 0) * 100)::int
    ) as priority
  from public.vendor_emails ve
  left join public.contacts c
    on c.id = ve.contact_id
  left join public.projects p
    on p.id = ve.project_id
  where ve.is_active = true
    and nullif(trim(ve.email), '') is not null
)
select distinct on (
  email,
  coalesce(project_id, '00000000-0000-0000-0000-000000000000'::uuid),
  target_type
)
  target_id,
  target_type,
  contact_id,
  project_id,
  project_name,
  vendor_name,
  vendor_name_normalized,
  email,
  relation_type,
  confidence,
  source,
  contact_name,
  company,
  trade,
  contact_aliases,
  company_aliases,
  priority
from base
order by
  email,
  coalesce(project_id, '00000000-0000-0000-0000-000000000000'::uuid),
  target_type,
  priority desc,
  target_id;

comment on view public.v_gmail_search_targets is
  'Camber-derived Gmail financial scrape targets, combining vendor/client emails with project affinity and search priority.';

alter table public.gmail_financial_pipeline_runs
  alter column label_id drop not null;

comment on column public.gmail_financial_pipeline_runs.label_id is
  'Optional Gmail label used for label-mode runs; null for Camber-intelligence search mode.';

alter table public.gmail_financial_receipts
  drop constraint if exists gmail_financial_receipts_source_check;

alter table public.gmail_financial_receipts
  add constraint gmail_financial_receipts_source_check
  check (source in ('gmail_scrape', 'gmail_camber_scrape'));

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
  if v_source not in ('gmail_scrape', 'gmail_camber_scrape') then
    raise exception 'invalid_receipt: source must be gmail_scrape or gmail_camber_scrape';
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
        source = excluded.source,
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
  'Atomic Gmail financial receipt upsert. Supports label-driven and Camber-intelligence scrape sources with canonical dedupe.';

create or replace function public.cron_fire_gmail_financial_scrape()
returns bigint
language plpgsql
security definer
as $$
declare
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_query text;
  v_outbound_sender text;
  v_request_id bigint;
  v_has_pg_net boolean;
  v_has_vault boolean;
begin
  select exists (select 1 from pg_extension where extname = 'pg_net') into v_has_pg_net;
  if not v_has_pg_net then
    raise notice 'cron_fire_gmail_financial_scrape: pg_net extension missing; skipping';
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

  v_query := coalesce(current_setting('app.settings.gmail_financial_query', true), '');
  v_outbound_sender := nullif(current_setting('app.settings.gmail_financial_outbound_sender', true), '');

  if v_anon_key is null or v_edge_secret is null then
    if not v_has_vault then
      raise notice 'cron_fire_gmail_financial_scrape: missing anon_key or edge_secret and supabase_vault not installed; skipping';
    else
      raise notice 'cron_fire_gmail_financial_scrape: missing anon_key or edge_secret, skipping';
    end if;
    return -1;
  end if;

  select net.http_post(
    url := v_base_url || '/functions/v1/gmail-financial-pipeline',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      'X-Source', 'gmail-financial-scrape'
    ),
    body := jsonb_strip_nulls(jsonb_build_object(
      'dry_run', false,
      'max_messages', 100,
      'max_targets', 40,
      'overlap_days', 2,
      'per_target_max_results', 8,
      'pipeline_key', 'gold_standard',
      'query', v_query,
      'outbound_sender', v_outbound_sender,
      'search_mode', 'camber_intel'
    ))
  ) into v_request_id;

  return v_request_id;
end;
$$;

comment on function public.cron_fire_gmail_financial_scrape() is
  'pg_net wrapper: invokes the Camber-intelligence Gmail financial scrape every 15 minutes without relying on Gmail labels.';

revoke execute on function public.cron_fire_gmail_financial_scrape() from public;
grant execute on function public.cron_fire_gmail_financial_scrape() to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (select 1 from cron.job where jobname = 'gmail_financial_scrape_every_15m') then
        perform cron.schedule(
          'gmail_financial_scrape_every_15m',
          '*/15 * * * *',
          $$select public.cron_fire_gmail_financial_scrape();$$
        );
      end if;
    exception
      when others then
        raise notice 'gmail_financial_scrape cron registration skipped: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron extension missing; gmail_financial_scrape_every_15m not scheduled';
  end if;
end;
$do$;
