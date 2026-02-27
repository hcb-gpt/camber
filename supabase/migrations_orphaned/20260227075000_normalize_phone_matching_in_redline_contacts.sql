begin;

create or replace view redline_contacts as
with contact_lookup as (
  select distinct on (phone10)
    c.id,
    c.name,
    c.phone,
    phone10
  from (
    select
      contacts.id,
      contacts.name,
      contacts.phone,
      right(regexp_replace(coalesce(contacts.phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) as phone10,
      contacts.updated_at
    from contacts
  ) c
  where c.phone10 <> ''::text
  order by c.phone10, c.updated_at desc nulls last, c.id
),
sms_norm as (
  select
    sms_messages.id,
    sms_messages.sent_at,
    sms_messages.content,
    sms_messages.direction,
    sms_messages.contact_name,
    sms_messages.contact_phone,
    right(regexp_replace(coalesce(sms_messages.contact_phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) as phone10
  from sms_messages
),
owner_phone_digits as (
  select distinct
    right(regexp_replace(coalesce(owner_phones.phone, ''::text), '\D'::text, ''::text, 'g'::text), 10) as phone10
  from owner_phones
  where owner_phones.active = true
),
call_stats as (
  select
    interactions.contact_id,
    count(*) as call_count,
    max(interactions.event_at_utc) as last_call_at
  from interactions
  where interactions.contact_id is not null
  group by interactions.contact_id
),
sms_stats as (
  select
    cl.id as contact_id,
    count(*) as sms_count,
    max(s.sent_at) as last_sms_at
  from sms_norm s
  join contact_lookup cl
    on cl.phone10 = s.phone10
  where s.phone10 <> ''::text
    and exists (
      select 1
      from sms_norm s2
      where s2.phone10 = s.phone10
        and s2.direction = 'inbound'::text
    )
    and not (
      s.phone10 in (
        select owner_phone_digits.phone10
        from owner_phone_digits
        where owner_phone_digits.phone10 <> ''::text
      )
    )
  group by cl.id
),
grading_cutoff as (
  select coalesce(
    (
      select redline_settings.value_timestamptz
      from redline_settings
      where redline_settings.key = 'grading_cutoff'::text
    ),
    '1970-01-01 00:00:00+00'::timestamp with time zone
  ) as cutoff
),
claim_stats as (
  select
    i.contact_id,
    count(distinct jc.id) as claim_count,
    count(distinct jc.id) filter (
      where jc.created_at >= (select grading_cutoff.cutoff from grading_cutoff)
        and not exists (
          select 1
          from claim_grades cg2
          where cg2.claim_id = jc.id
            and cg2.graded_at >= (select grading_cutoff.cutoff from grading_cutoff)
        )
    ) as ungraded_count
  from interactions i
  join journal_claims jc
    on jc.call_id = i.interaction_id
  where i.contact_id is not null
  group by i.contact_id
),
pending_review as (
  select
    coalesce(i.contact_id, c_match.id) as contact_id,
    rq.id as queue_id
  from review_queue rq
  join interactions i
    on i.interaction_id = rq.interaction_id
  left join lateral (
    select c.id
    from contacts c
    where i.contact_id is null
      and i.contact_name is not null
      and c.name = i.contact_name
    order by c.updated_at desc nulls last, c.id
    limit 1
  ) c_match
    on true
  where rq.status = 'pending'::text
    and rq.created_at >= (select grading_cutoff.cutoff from grading_cutoff)
),
review_stats as (
  select
    pending_review.contact_id,
    count(distinct pending_review.queue_id) as ungraded_count
  from pending_review
  where pending_review.contact_id is not null
  group by pending_review.contact_id
),
last_call as (
  select distinct on (i.contact_id)
    i.contact_id,
    left(i.human_summary, 80) as snippet,
    cr.direction,
    'call'::text as interaction_type,
    i.event_at_utc
  from interactions i
  left join calls_raw cr
    on cr.interaction_id = i.interaction_id
  where i.contact_id is not null
  order by i.contact_id, i.event_at_utc desc nulls last
),
last_sms as (
  select distinct on (cl.id)
    cl.id as contact_id,
    left(s.content, 80) as snippet,
    s.direction,
    'sms'::text as interaction_type,
    s.sent_at as event_at_utc
  from sms_norm s
  join contact_lookup cl
    on cl.phone10 = s.phone10
  where s.phone10 <> ''::text
    and exists (
      select 1
      from sms_norm s2
      where s2.phone10 = s.phone10
        and s2.direction = 'inbound'::text
    )
    and not (
      s.phone10 in (
        select owner_phone_digits.phone10
        from owner_phone_digits
        where owner_phone_digits.phone10 <> ''::text
      )
    )
  order by cl.id, s.sent_at desc nulls last
),
latest as (
  select distinct on (combined.contact_id)
    combined.contact_id,
    combined.snippet as last_snippet,
    combined.direction as last_direction,
    combined.interaction_type as last_interaction_type
  from (
    select
      last_call.contact_id,
      last_call.snippet,
      last_call.direction,
      last_call.interaction_type,
      last_call.event_at_utc
    from last_call
    union all
    select
      last_sms.contact_id,
      last_sms.snippet,
      last_sms.direction,
      last_sms.interaction_type,
      last_sms.event_at_utc
    from last_sms
  ) combined
  order by combined.contact_id, combined.event_at_utc desc nulls last
)
select
  c.id as contact_id,
  c.name as contact_name,
  c.phone as contact_phone,
  coalesce(cs.call_count, 0::bigint)::integer as call_count,
  coalesce(ss.sms_count, 0::bigint)::integer as sms_count,
  coalesce(cls.claim_count, 0::bigint)::integer as claim_count,
  coalesce(rs.ungraded_count, 0::bigint)::integer as ungraded_count,
  coalesce(greatest(cs.last_call_at, ss.last_sms_at), cs.last_call_at, ss.last_sms_at) as last_activity,
  lt.last_snippet,
  lt.last_direction,
  lt.last_interaction_type
from contacts c
left join call_stats cs
  on cs.contact_id = c.id
left join sms_stats ss
  on ss.contact_id = c.id
left join claim_stats cls
  on cls.contact_id = c.id
left join review_stats rs
  on rs.contact_id = c.id
left join latest lt
  on lt.contact_id = c.id
where coalesce(cs.call_count, 0::bigint) > 0
   or coalesce(ss.sms_count, 0::bigint) > 0
order by coalesce(greatest(cs.last_call_at, ss.last_sms_at), cs.last_call_at, ss.last_sms_at) desc nulls last;

commit;
