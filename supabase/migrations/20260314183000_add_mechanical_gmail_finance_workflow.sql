-- Mechanical Gmail finance workflow:
-- 1) Registry-driven Gmail retrieval profiles.
-- 2) Durable candidate table for every retrieved Gmail message.
-- 3) Exception-queue view for uncertain finance candidates.

create table if not exists public.gmail_query_profiles (
  id uuid primary key default gen_random_uuid(),
  profile_set text not null default 'finance_v1',
  profile_slug text not null,
  priority integer not null default 100,
  gmail_query text not null,
  class_hint text,
  active boolean not null default true,
  mailbox_scope text not null default 'zack@heartwoodcustombuilders.com',
  label_mirror_name text,
  effective_after_date date,
  notes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists gmail_query_profiles_profile_set_slug_uq
  on public.gmail_query_profiles (profile_set, profile_slug);

create index if not exists gmail_query_profiles_active_priority_idx
  on public.gmail_query_profiles (profile_set, active, priority desc, profile_slug);

comment on table public.gmail_query_profiles is
  'Pipeline-managed Gmail retrieval profiles for the mechanical finance workflow.';

create table if not exists public.gmail_financial_candidates (
  id uuid primary key default gen_random_uuid(),
  message_id text not null,
  thread_id text,
  internal_date timestamptz,
  subject text,
  from_header text,
  snippet text,
  matched_profile_slugs text[] not null default '{}'::text[],
  matched_class_hints text[] not null default '{}'::text[],
  matched_query_fragments text[] not null default '{}'::text[],
  raw_headers jsonb not null default '[]'::jsonb,
  body_excerpt text,
  run_id uuid references public.gmail_financial_pipeline_runs(id) on delete set null,
  retrieval_state text not null default 'retrieved'
    check (retrieval_state in ('retrieved')),
  classification_state text not null default 'pending'
    check (classification_state in ('pending', 'classified', 'failed')),
  doc_type text
    check (doc_type in (
      'vendor_invoice',
      'vendor_receipt',
      'client_pay_app',
      'client_draw_request',
      'statement',
      'reminder',
      'tax_form',
      'noise',
      'unknown'
    )),
  finance_relevance_score numeric(5,4),
  decision text
    check (decision in ('accept_extract', 'accept_non_extract', 'review', 'reject')),
  decision_reason text,
  classifier_version text,
  classifier_meta jsonb not null default '{}'::jsonb,
  review_state text not null default 'pending'
    check (review_state in ('pending', 'resolved')),
  review_resolution text,
  review_resolved_at_utc timestamptz,
  extraction_state text not null default 'pending'
    check (extraction_state in ('pending', 'extracted', 'skipped', 'failed')),
  extraction_receipt_id uuid references public.gmail_financial_receipts(id) on delete set null,
  extraction_error text,
  extraction_meta jsonb not null default '{}'::jsonb,
  extracted_at_utc timestamptz,
  first_retrieved_at_utc timestamptz not null default now(),
  last_retrieved_at_utc timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists gmail_financial_candidates_message_id_uq
  on public.gmail_financial_candidates (message_id);

create index if not exists gmail_financial_candidates_review_idx
  on public.gmail_financial_candidates (decision, review_state, last_retrieved_at_utc desc);

create index if not exists gmail_financial_candidates_extract_idx
  on public.gmail_financial_candidates (decision, extraction_state, last_retrieved_at_utc desc);

create index if not exists gmail_financial_candidates_run_idx
  on public.gmail_financial_candidates (run_id, last_retrieved_at_utc desc);

create index if not exists gmail_financial_candidates_thread_idx
  on public.gmail_financial_candidates (thread_id)
  where thread_id is not null;

comment on table public.gmail_financial_candidates is
  'Durable Gmail finance candidate pool: one row per Gmail message id with retrieval, classification, review, and extraction state.';

create or replace view public.v_gmail_financial_review_queue
with (security_invoker = true) as
select
  c.id as candidate_id,
  c.message_id,
  c.thread_id,
  c.internal_date,
  c.subject,
  c.from_header,
  c.snippet,
  c.body_excerpt,
  c.matched_profile_slugs,
  c.matched_class_hints,
  c.finance_relevance_score,
  c.doc_type,
  c.decision,
  c.decision_reason,
  c.classifier_version,
  c.classifier_meta,
  c.review_state,
  c.run_id,
  c.first_retrieved_at_utc,
  c.last_retrieved_at_utc,
  c.updated_at
from public.gmail_financial_candidates c
where c.decision = 'review'
  and c.review_state = 'pending'
order by c.last_retrieved_at_utc desc, c.internal_date desc nulls last;

comment on view public.v_gmail_financial_review_queue is
  'Mechanical Gmail finance exception queue: unresolved candidates that require human review.';

alter table public.gmail_query_profiles enable row level security;
alter table public.gmail_financial_candidates enable row level security;

drop policy if exists "service_role_all_gmail_query_profiles" on public.gmail_query_profiles;
create policy "service_role_all_gmail_query_profiles"
  on public.gmail_query_profiles
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

drop policy if exists "service_role_all_gmail_financial_candidates" on public.gmail_financial_candidates;
create policy "service_role_all_gmail_financial_candidates"
  on public.gmail_financial_candidates
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

grant select, insert, update, delete on table public.gmail_query_profiles to service_role;
grant select, insert, update, delete on table public.gmail_financial_candidates to service_role;
grant select on table public.v_gmail_financial_review_queue to service_role;

create or replace function public.upsert_gmail_financial_candidate(
  p_candidate jsonb
)
returns table (
  candidate_id uuid,
  classification_state text,
  decision text,
  extraction_state text,
  last_retrieved_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message_id text;
  v_thread_id text;
  v_internal_date timestamptz;
  v_subject text;
  v_from_header text;
  v_snippet text;
  v_body_excerpt text;
  v_run_id uuid;
  v_matched_profile_slugs text[] := '{}'::text[];
  v_matched_class_hints text[] := '{}'::text[];
  v_matched_query_fragments text[] := '{}'::text[];
  v_raw_headers jsonb := '[]'::jsonb;
begin
  if p_candidate is null or jsonb_typeof(p_candidate) <> 'object' then
    raise exception 'invalid_candidate: p_candidate must be a json object';
  end if;

  v_message_id := nullif(trim(coalesce(p_candidate->>'message_id', '')), '');
  if v_message_id is null then
    raise exception 'invalid_candidate: message_id is required';
  end if;

  v_thread_id := nullif(trim(coalesce(p_candidate->>'thread_id', '')), '');
  v_subject := nullif(trim(coalesce(p_candidate->>'subject', '')), '');
  v_from_header := nullif(trim(coalesce(p_candidate->>'from_header', '')), '');
  v_snippet := nullif(trim(coalesce(p_candidate->>'snippet', '')), '');
  v_body_excerpt := nullif(trim(coalesce(p_candidate->>'body_excerpt', '')), '');

  if p_candidate ? 'internal_date' and coalesce(p_candidate->>'internal_date', '') <> '' then
    v_internal_date := (p_candidate->>'internal_date')::timestamptz;
  end if;

  if p_candidate ? 'run_id' and coalesce(p_candidate->>'run_id', '') <> '' then
    if p_candidate->>'run_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'invalid_candidate: run_id must be uuid when provided';
    end if;
    v_run_id := (p_candidate->>'run_id')::uuid;
  end if;

  if jsonb_typeof(coalesce(p_candidate->'matched_profile_slugs', '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_candidate: matched_profile_slugs must be an array';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}'::text[])
    into v_matched_profile_slugs
  from (
    select nullif(trim(value), '') as x
    from jsonb_array_elements_text(coalesce(p_candidate->'matched_profile_slugs', '[]'::jsonb))
  ) rows
  where x is not null;
  if coalesce(array_length(v_matched_profile_slugs, 1), 0) = 0 then
    raise exception 'invalid_candidate: matched_profile_slugs must not be empty';
  end if;

  if jsonb_typeof(coalesce(p_candidate->'matched_class_hints', '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_candidate: matched_class_hints must be an array';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}'::text[])
    into v_matched_class_hints
  from (
    select nullif(trim(value), '') as x
    from jsonb_array_elements_text(coalesce(p_candidate->'matched_class_hints', '[]'::jsonb))
  ) rows
  where x is not null;

  if jsonb_typeof(coalesce(p_candidate->'matched_query_fragments', '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_candidate: matched_query_fragments must be an array';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}'::text[])
    into v_matched_query_fragments
  from (
    select nullif(trim(value), '') as x
    from jsonb_array_elements_text(coalesce(p_candidate->'matched_query_fragments', '[]'::jsonb))
  ) rows
  where x is not null;

  if p_candidate ? 'raw_headers' then
    if jsonb_typeof(p_candidate->'raw_headers') <> 'array' then
      raise exception 'invalid_candidate: raw_headers must be an array when provided';
    end if;
    v_raw_headers := p_candidate->'raw_headers';
  end if;

  insert into public.gmail_financial_candidates (
    message_id,
    thread_id,
    internal_date,
    subject,
    from_header,
    snippet,
    matched_profile_slugs,
    matched_class_hints,
    matched_query_fragments,
    raw_headers,
    body_excerpt,
    run_id,
    retrieval_state,
    first_retrieved_at_utc,
    last_retrieved_at_utc
  )
  values (
    v_message_id,
    v_thread_id,
    v_internal_date,
    v_subject,
    v_from_header,
    v_snippet,
    v_matched_profile_slugs,
    v_matched_class_hints,
    v_matched_query_fragments,
    v_raw_headers,
    v_body_excerpt,
    v_run_id,
    'retrieved',
    now(),
    now()
  )
  on conflict (message_id) do update
    set thread_id = coalesce(excluded.thread_id, public.gmail_financial_candidates.thread_id),
        internal_date = case
          when excluded.internal_date is null then public.gmail_financial_candidates.internal_date
          when public.gmail_financial_candidates.internal_date is null then excluded.internal_date
          else greatest(public.gmail_financial_candidates.internal_date, excluded.internal_date)
        end,
        subject = coalesce(excluded.subject, public.gmail_financial_candidates.subject),
        from_header = coalesce(excluded.from_header, public.gmail_financial_candidates.from_header),
        snippet = coalesce(excluded.snippet, public.gmail_financial_candidates.snippet),
        matched_profile_slugs = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.gmail_financial_candidates.matched_profile_slugs, '{}'::text[])
            || coalesce(excluded.matched_profile_slugs, '{}'::text[])
          ) as merged(x)
        ),
        matched_class_hints = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.gmail_financial_candidates.matched_class_hints, '{}'::text[])
            || coalesce(excluded.matched_class_hints, '{}'::text[])
          ) as merged(x)
        ),
        matched_query_fragments = (
          select coalesce(array_agg(distinct x order by x), '{}'::text[])
          from unnest(
            coalesce(public.gmail_financial_candidates.matched_query_fragments, '{}'::text[])
            || coalesce(excluded.matched_query_fragments, '{}'::text[])
          ) as merged(x)
        ),
        raw_headers = case
          when jsonb_typeof(excluded.raw_headers) = 'array' and jsonb_array_length(excluded.raw_headers) > 0
            then excluded.raw_headers
          else public.gmail_financial_candidates.raw_headers
        end,
        body_excerpt = coalesce(excluded.body_excerpt, public.gmail_financial_candidates.body_excerpt),
        run_id = coalesce(excluded.run_id, public.gmail_financial_candidates.run_id),
        retrieval_state = 'retrieved',
        last_retrieved_at_utc = now(),
        updated_at = now()
  returning
    public.gmail_financial_candidates.id,
    public.gmail_financial_candidates.classification_state,
    public.gmail_financial_candidates.decision,
    public.gmail_financial_candidates.extraction_state,
    public.gmail_financial_candidates.last_retrieved_at_utc
  into
    candidate_id,
    classification_state,
    decision,
    extraction_state,
    last_retrieved_at_utc;

  return next;
end;
$$;

comment on function public.upsert_gmail_financial_candidate(jsonb) is
  'Idempotent Gmail finance candidate upsert keyed by Gmail message id. Merges profile hits and refreshes retrieval metadata.';

revoke execute on function public.upsert_gmail_financial_candidate(jsonb) from public;
grant execute on function public.upsert_gmail_financial_candidate(jsonb) to service_role;

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
values
  (
    'finance_v1',
    'high_conf_inbound_receipts',
    400,
    '-from:{me robyn@allytax.us gmelling321@gmail.com do-not-reply@gong.io} -to:{gmelling321@gmail.com} -subject:{re: fwd:} invoice -{estimate amazon "Heartwood Custom Builders Invoice" "from Heartwood"}',
    'vendor_receipt',
    true,
    'zack@heartwoodcustombuilders.com',
    '1',
    '2025-04-01',
    jsonb_build_object('seed_source', 'chad_manual_filter_v1', 'description', 'High-confidence inbound receipts')
  ),
  (
    'finance_v1',
    'high_conf_invoice_traffic',
    350,
    '-in:sent -from:{me chad@heartwoodcustombuilders.com zj.sittler@icloud.com zack@heartwoodcustombuilders.com robyn@allytax.us do-not-reply@gong.io mailer-daemon gmelling321@gmail.com} -to:{gmelling321@gmail.com} -subject:{"Re:" "RE:" "Fw:" "Fwd:" "FW:" "receipt" "payment receipt" "Receipt for Payment" "Your receipt" "payment confirmation"} subject:invoice -{estimate amazon "Heartwood Custom Builders Invoice" "from Heartwood"}',
    'vendor_invoice',
    true,
    'zack@heartwoodcustombuilders.com',
    '2',
    '2025-04-01',
    jsonb_build_object('seed_source', 'chad_manual_filter_v1', 'description', 'High-confidence invoice traffic')
  ),
  (
    'finance_v1',
    'broad_finance_candidate_net',
    200,
    '( subject:{"invoice" "invoices" "Invoice from" "Invoices from" "INV-" "INV #" "pro forma invoice" "application for payment" "pay app" "progress billing" "progress bill" "draw request" "request for payment" "AIA G702" "G703" "Joist - View Document" "View invoice" "View Invoices" "Pay invoice" "Pay Invoices" "amount due" "balance due" "payment due" "statement" "past due" "overdue" "reminder" "Payment:"} OR (invoice -from:{me chad@heartwoodcustombuilders.com admin@heartwoodcustombuilders.com chad@hcb.llc zj.sittler@icloud.com zack@heartwoodcustombuilders.com} -subject:{"Re:" "Fd:" "FW:"} -has:attachment) ) -subject:{"receipt" "payment receipt" "receipt for payment" "your receipt" "payment confirmation" "payment received" "has been paid" "paid" "thank you for your payment"} -from:{mailer-daemon admin@heartwoodcustombuilders.com chad@heartwoodcustombuilders.com chad@hcb.llc admin@hcb.llc} -{estimate amazon "Heartwood Custom Builders Invoice" "from Heartwood"}',
    'finance_candidate',
    true,
    'zack@heartwoodcustombuilders.com',
    '3',
    '2025-04-01',
    jsonb_build_object('seed_source', 'chad_manual_filter_v1', 'description', 'Broad finance candidate net before AI classification')
  ),
  (
    'finance_v1',
    'vendor_platform_exception_path',
    300,
    '((from:zj.sittler@icloud.com subject:"Joist - View Document") OR (-in:sent -from:{me zack@heartwoodcustombuilders.com robyn@allytax.us do-not-reply@gong.io mailer-daemon gmelling321@gmail.com} -to:{gmelling321@gmail.com} -subject:{re: fwd: receipt "payment receipt" "payment confirmation" "payment received" paid "thank you for your payment"} -(estimate amazon "Heartwood Custom Builders Invoice" "from Heartwood") (subject:{invoice invoices "invoice from" "invoices from" "invoice #" "inv #" "inv-" "pay invoice" "view invoice" "balance due" "payment due" "past due" overdue "statement of account" "application for payment" "pay app" "AIA G702" G703} OR from:quickbooks@notification.intuit.com)))',
    'vendor_invoice',
    true,
    'zack@heartwoodcustombuilders.com',
    '4',
    '2025-04-01',
    jsonb_build_object('seed_source', 'chad_manual_filter_v1', 'description', 'Vendor/platform exception path for Joist and QuickBooks-like traffic')
  )
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
