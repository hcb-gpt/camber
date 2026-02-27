-- Layer 3 foundation: source reliability table + idempotent journal seed path.
-- This migration is additive and safe to re-run.

create table if not exists public.source_reliability (
  contact_id uuid not null references public.contacts(id) on delete cascade,
  domain text not null,
  reliability_score numeric(4,3) not null default 0.700,
  total_claims integer not null default 0,
  confirmed_claims integer not null default 0,
  disputed_claims integer not null default 0,
  last_assessed_at timestamptz not null default now(),
  assessment_method text not null default 'seed_from_journal',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint source_reliability_pk primary key (contact_id, domain),
  constraint source_reliability_score_bounds_chk
    check (reliability_score >= 0 and reliability_score <= 1),
  constraint source_reliability_count_bounds_chk
    check (total_claims >= 0 and confirmed_claims >= 0 and disputed_claims >= 0),
  constraint source_reliability_count_consistency_chk
    check (confirmed_claims <= total_claims and disputed_claims <= total_claims)
);
create index if not exists source_reliability_domain_idx
  on public.source_reliability (domain);
create index if not exists source_reliability_score_idx
  on public.source_reliability (reliability_score);
create index if not exists source_reliability_last_assessed_idx
  on public.source_reliability (last_assessed_at desc);
comment on table public.source_reliability is
  'Layer-3 provenance/reliability baseline keyed by contact + domain. Initial seed defaults reliability_score to 0.700.';
comment on column public.source_reliability.assessment_method is
  'Provenance for last assessment update (e.g., seed_from_journal, outcome_validation).';
create or replace function public.source_reliability_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists trg_source_reliability_updated_at on public.source_reliability;
create trigger trg_source_reliability_updated_at
before update on public.source_reliability
for each row
execute function public.source_reliability_set_updated_at();
alter table public.source_reliability enable row level security;
drop policy if exists "service_role_all_source_reliability" on public.source_reliability;
create policy "service_role_all_source_reliability"
  on public.source_reliability
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');
create or replace function public.seed_source_reliability_from_journal_claims(
  p_assessment_method text default 'seed_from_journal'
)
returns table (
  upserted_rows bigint,
  total_rows bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_upserted bigint := 0;
  v_total bigint := 0;
  v_method text := coalesce(nullif(trim(p_assessment_method), ''), 'seed_from_journal');
begin
  with aggregated as (
    select
      jc.speaker_contact_id as contact_id,
      case
        when jc.claim_type in ('deadline', 'commitment', 'update', 'blocker') then 'scheduling'
        when jc.claim_type in ('requirement', 'preference') then 'materials'
        else 'general'
      end as domain,
      count(*)::integer as total_claims,
      count(*) filter (
        where coalesce(jc.claim_confirmation_state, 'unconfirmed') = 'confirmed'
      )::integer as confirmed_claims,
      count(*) filter (
        where coalesce(jc.relationship, '') = 'conflicts'
      )::integer as disputed_claims
    from public.journal_claims jc
    where jc.speaker_contact_id is not null
      and jc.active = true
    group by 1, 2
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
      a.contact_id,
      a.domain,
      0.700::numeric(4,3) as reliability_score,
      a.total_claims,
      a.confirmed_claims,
      least(a.disputed_claims, a.total_claims) as disputed_claims,
      now(),
      v_method
    from aggregated a
    on conflict (contact_id, domain) do update
      set total_claims = excluded.total_claims,
          confirmed_claims = excluded.confirmed_claims,
          disputed_claims = excluded.disputed_claims,
          -- Preserve current tuned score on reseed; default stays 0.700 on first insert.
          reliability_score = coalesce(public.source_reliability.reliability_score, 0.700::numeric(4,3)),
          last_assessed_at = excluded.last_assessed_at,
          assessment_method = excluded.assessment_method,
          updated_at = now()
    returning 1
  )
  select count(*) into v_upserted from upserted;

  select count(*) into v_total from public.source_reliability;

  return query select v_upserted, v_total;
end;
$$;
comment on function public.seed_source_reliability_from_journal_claims(text) is
  'Seeds or refreshes source_reliability from active journal_claims grouped by speaker_contact_id and domain; preserves tuned reliability_score on reseed.';
grant execute on function public.seed_source_reliability_from_journal_claims(text) to service_role;
-- Initial idempotent seed pass.
select * from public.seed_source_reliability_from_journal_claims('seed_from_journal');
