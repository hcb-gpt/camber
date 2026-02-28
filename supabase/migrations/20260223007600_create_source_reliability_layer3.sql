-- Layer 3 provenance reliability foundation (additive)
-- Scope:
-- 1) Create public.source_reliability table
-- 2) Add deterministic seed helper from journal_claims.speaker_contact_id
-- 3) Apply initial seed in-migration (idempotent)
--
-- Epistemology:
-- - Layer 3: hadith-style source grading scaffold
-- - Layer 4: svatah default prior -> reliability_score = 0.700

create table if not exists public.source_reliability (
  contact_id uuid not null references public.contacts(id) on delete cascade,
  domain text not null,
  reliability_score numeric(4,3) not null default 0.700
    check (reliability_score >= 0 and reliability_score <= 1),
  total_claims integer not null default 0
    check (total_claims >= 0),
  confirmed_claims integer not null default 0
    check (confirmed_claims >= 0),
  disputed_claims integer not null default 0
    check (disputed_claims >= 0),
  last_assessed_at timestamptz,
  assessment_method text not null default 'seed_from_journal',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint source_reliability_pk primary key (contact_id, domain),
  constraint source_reliability_domain_ck
    check (domain in ('scheduling', 'materials', 'general')),
  constraint source_reliability_counts_ck
    check (confirmed_claims + disputed_claims <= total_claims)
);
create index if not exists source_reliability_domain_score_idx
  on public.source_reliability (domain, reliability_score desc);
create index if not exists source_reliability_last_assessed_idx
  on public.source_reliability (last_assessed_at desc nulls last);
create index if not exists source_reliability_updated_idx
  on public.source_reliability (updated_at desc);
create or replace function public.trg_source_reliability_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_source_reliability_touch_updated_at on public.source_reliability;
create trigger trg_source_reliability_touch_updated_at
before update on public.source_reliability
for each row execute function public.trg_source_reliability_touch_updated_at();
alter table public.source_reliability enable row level security;
drop policy if exists "service_role_all_source_reliability" on public.source_reliability;
create policy "service_role_all_source_reliability"
  on public.source_reliability
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');
drop function if exists public.seed_source_reliability_from_journal_claims(text);
create or replace function public.seed_source_reliability_from_journal_claims(
  p_assessment_method text default 'seed_from_journal'
)
returns table (
  inserted_count integer,
  updated_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_speaker_col boolean;
begin
  select exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'journal_claims'
      and c.column_name = 'speaker_contact_id'
  )
  into v_has_speaker_col;

  if not v_has_speaker_col then
    return query
    select 0::integer, 0::integer;
    return;
  end if;

  return query
  with seed as (
    select
      jc.speaker_contact_id as contact_id,
      case
        when jc.claim_type in ('commitment', 'deadline', 'decision', 'update') then 'scheduling'
        when jc.claim_text ~* '(material|lumber|tile|paint|fixture|hardware|appliance|window|door|roof|cabinet)' then 'materials'
        else 'general'
      end as domain,
      count(*)::integer as total_claims
    from public.journal_claims jc
    where jc.speaker_contact_id is not null
    group by jc.speaker_contact_id,
      case
        when jc.claim_type in ('commitment', 'deadline', 'decision', 'update') then 'scheduling'
        when jc.claim_text ~* '(material|lumber|tile|paint|fixture|hardware|appliance|window|door|roof|cabinet)' then 'materials'
        else 'general'
      end
  ),
  upserted as (
    insert into public.source_reliability (
      contact_id,
      domain,
      reliability_score,
      total_claims,
      confirmed_claims,
      disputed_claims,
      last_assessed_at,
      assessment_method
    )
    select
      s.contact_id,
      s.domain,
      0.700,
      s.total_claims,
      0,
      0,
      now(),
      coalesce(nullif(trim(p_assessment_method), ''), 'seed_from_journal')
    from seed s
    on conflict (contact_id, domain) do update
      set total_claims = greatest(
            excluded.total_claims,
            public.source_reliability.confirmed_claims + public.source_reliability.disputed_claims
          ),
          last_assessed_at = excluded.last_assessed_at,
          assessment_method = excluded.assessment_method
    returning (xmax = 0) as inserted
  )
  select
    count(*) filter (where inserted)::integer as inserted_count,
    count(*) filter (where not inserted)::integer as updated_count
  from upserted;
end;
$$;
grant execute on function public.seed_source_reliability_from_journal_claims(text)
  to service_role;
comment on table public.source_reliability is
  'Layer-3 provenance reliability table: per-contact, per-domain reliability priors and counters.';
comment on function public.seed_source_reliability_from_journal_claims(text) is
  'Idempotent seed/upsert from journal_claims speaker_contact_id grouped by domain. Initializes reliability_score to 0.700 (svatah prior).';
create or replace view public.v_source_reliability_ops as
select
  sr.contact_id,
  c.name as contact_name,
  c.contact_type,
  c.company,
  sr.domain,
  sr.reliability_score,
  sr.total_claims,
  sr.confirmed_claims,
  sr.disputed_claims,
  sr.last_assessed_at,
  sr.assessment_method,
  sr.updated_at
from public.source_reliability sr
left join public.contacts c
  on c.id = sr.contact_id;
comment on view public.v_source_reliability_ops is
  'Operator view for source reliability by contact/domain with basic contact context.';
-- Initial seed is idempotent and safe to replay.
select * from public.seed_source_reliability_from_journal_claims('seed_from_journal');
