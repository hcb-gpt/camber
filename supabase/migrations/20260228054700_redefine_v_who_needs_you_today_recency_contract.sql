-- Redefine v_who_needs_you_today recency contract:
-- all signal categories use a 7-day recency window.

create or replace view public.v_who_needs_you_today as
with callback_promises as (
  select
    p.name as project,
    jc.claim_text as detail,
    jc.speaker_label as speaker,
    jc.created_at,
    'promise'::text as category,
    row_number() over (
      partition by p.id
      order by jc.created_at desc
    ) as rn
  from public.journal_claims jc
  left join public.projects p
    on p.id = jc.project_id
  where jc.claim_type = 'commitment'
    and jc.created_at > now() - interval '7 days'
    and (
      jc.claim_text ilike '%will call%'
      or jc.claim_text ilike '%will text%'
      or jc.claim_text ilike '%will send%'
      or jc.claim_text ilike '%will let%know%'
      or jc.claim_text ilike '%will get back%'
      or jc.claim_text ilike '%will provide%'
      or jc.claim_text ilike '%will come by%'
      or jc.claim_text ilike '%will stop by%'
    )
),
blockers as (
  select
    p.name as project,
    jol.description as detail,
    null::text as speaker,
    jol.created_at,
    case
      when jol.description ilike '%need hours%'
        or jol.description ilike '%need work%'
        or jol.description ilike '%guys need%' then 'livelihood'::text
      else 'blocked'::text
    end as category,
    row_number() over (
      partition by p.id
      order by jol.created_at desc
    ) as rn
  from public.journal_open_loops jol
  join public.projects p
    on p.id = jol.project_id
  where jol.status = 'open'
    and jol.loop_type = 'blocker'
    and jol.created_at > now() - interval '7 days'
),
concerns as (
  select
    p.name as project,
    jc.claim_text as detail,
    jc.speaker_label as speaker,
    jc.created_at,
    case
      when jc.claim_text ilike '%every dollar%'
        or jc.claim_text ilike '%over budget%'
        or jc.claim_text ilike '%cost%'
        or jc.claim_text ilike '%price%increase%' then 'money_worry'::text
      when jc.claim_text ilike '%overwhelm%'
        or jc.claim_text ilike '%overwork%'
        or jc.claim_text ilike '%stressed%' then 'burnout'::text
      else 'concern'::text
    end as category,
    row_number() over (
      partition by p.id
      order by jc.created_at desc
    ) as rn
  from public.journal_claims jc
  left join public.projects p
    on p.id = jc.project_id
  where jc.claim_type = 'concern'
    and jc.created_at > now() - interval '7 days'
),
silent_clients as (
  select
    mb.project_name as project,
    ('No calls in ' || mb.days_since_last_call || ' days - last was ' || coalesce(mb.top_contact, 'unknown'))::text as detail,
    null::text as speaker,
    now() - ((mb.days_since_last_call || ' days')::interval) as created_at,
    'gone_quiet'::text as category,
    1 as rn
  from public.v_monday_brief_data mb
  where mb.days_since_last_call > 14
    and mb.risk_score > 50
)
select
  category,
  project,
  detail,
  speaker,
  created_at,
  round(extract(epoch from now() - created_at) / 3600::numeric, 1) as hours_ago
from (
  select project, detail, speaker, created_at, category, rn
  from blockers
  where category = 'livelihood'

  union all

  select project, detail, speaker, created_at, category, rn
  from concerns
  where category = 'money_worry'
    and rn <= 2

  union all

  select project, detail, speaker, created_at, category, rn
  from concerns
  where category = 'burnout'
    and rn <= 2

  union all

  select project, detail, speaker, created_at, category, rn
  from callback_promises
  where rn <= 3

  union all

  select project, detail, speaker, created_at, category, rn
  from blockers
  where category = 'blocked'
    and rn <= 2

  union all

  select project, detail, speaker, created_at, category, rn
  from concerns
  where category = 'concern'
    and rn <= 2

  union all

  select project, detail, speaker, created_at, category, rn
  from silent_clients
) people
order by
  case category
    when 'livelihood' then 0
    when 'money_worry' then 1
    when 'burnout' then 2
    when 'promise' then 3
    when 'blocked' then 4
    when 'concern' then 5
    when 'gone_quiet' then 6
    else 7
  end,
  round(extract(epoch from now() - created_at) / 3600::numeric, 1) asc;

comment on view public.v_who_needs_you_today is
'People signal feed with explicit 7-day recency for promise/blocker/concern categories; silent-client rows remain risk-based from monday brief.';

