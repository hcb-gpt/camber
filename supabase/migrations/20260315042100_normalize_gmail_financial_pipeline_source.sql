update public.gmail_financial_receipts
set source = 'gmail_scrape'
where source = 'gmail_camber_scrape';

drop trigger if exists gmail_financial_receipts_normalize_source_tg
  on public.gmail_financial_receipts;

drop function if exists public.normalize_gmail_financial_receipt_source();

create function public.normalize_gmail_financial_receipt_source()
returns trigger
language plpgsql
as $$
begin
  if new.source is null or btrim(new.source) = '' then
    new.source := 'gmail_scrape';
  elsif lower(btrim(new.source)) = 'gmail_camber_scrape' then
    new.source := 'gmail_scrape';
  else
    new.source := 'gmail_scrape';
  end if;
  return new;
end;
$$;

create trigger gmail_financial_receipts_normalize_source_tg
before insert or update on public.gmail_financial_receipts
for each row
execute function public.normalize_gmail_financial_receipt_source();

alter table public.gmail_financial_receipts
  drop constraint if exists gmail_financial_receipts_source_check;

alter table public.gmail_financial_receipts
  add constraint gmail_financial_receipts_source_check
  check (source = 'gmail_scrape');

create or replace view public.v_gmail_financial_receipts_gandalf_export as
select
  r.id,
  r.vendor,
  r.total,
  coalesce(r.job_name, p.name) as job_name,
  r.receipt_date,
  r.invoice_or_transaction,
  'gmail_scrape'::text as source,
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
