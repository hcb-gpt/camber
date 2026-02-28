-- DB proof: attach interaction_ids for missing Beside-vs-Redline call tuples.
-- Receipt target:
--   db_proof__missing_calls_vs_beside_interaction_ids__data1__20260228
--
-- Usage:
--   scripts/query.sh --file scripts/sql/missing_calls_vs_beside_interaction_ids_data1_20260228.sql

\echo 'Q1) Tuple-level classification with interaction IDs'
with input_tuples(phone_raw, event_at_utc) as (
  values
    ('17065559876', '2026-02-27 22:20:30+00'::timestamptz),
    ('16788338072', '2026-02-27 12:51:19+00'::timestamptz),
    ('16784772532', '2026-02-26 20:23:38+00'::timestamptz),
    ('14044017599', '2026-02-26 18:23:23+00'::timestamptz),
    ('17064743770', '2026-02-26 15:52:23+00'::timestamptz),
    ('17709829800', '2026-02-26 14:50:27+00'::timestamptz),
    ('14043727648', '2026-02-25 21:27:27+00'::timestamptz),
    ('17702677027', '2026-02-25 19:45:09+00'::timestamptz),
    ('14048494832', '2026-02-25 16:20:33+00'::timestamptz),
    ('18662989094', '2026-02-25 14:11:58+00'::timestamptz)
),
tuples as (
  select
    phone_raw,
    right(regexp_replace(phone_raw, '\D', '', 'g'), 10) as phone10,
    event_at_utc
  from input_tuples
),
beside_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    b.beside_event_id,
    b.beside_event_type,
    b.occurred_at_utc,
    b.ingested_at_utc,
    b.camber_interaction_id,
    abs(extract(epoch from (b.occurred_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', b.occurred_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.beside_thread_events b
    on right(regexp_replace(coalesce(b.contact_phone_e164, ''), '\D', '', 'g'), 10) = t.phone10
   and lower(coalesce(b.beside_event_type, '')) like 'c%'
   and abs(extract(epoch from (b.occurred_at_utc - t.event_at_utc))) <= 120
),
calls_call_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    c.interaction_id,
    c.channel,
    c.event_at_utc as calls_event_at_utc,
    c.ingested_at_utc,
    abs(extract(epoch from (c.event_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', c.event_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.calls_raw c
    on right(regexp_replace(coalesce(c.other_party_phone, ''), '\D', '', 'g'), 10) = t.phone10
   and abs(extract(epoch from (c.event_at_utc - t.event_at_utc))) <= 120
   and lower(coalesce(c.channel, '')) in ('call', 'phone')
),
calls_non_call_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    c.interaction_id,
    c.channel,
    c.event_at_utc as calls_event_at_utc,
    c.ingested_at_utc,
    abs(extract(epoch from (c.event_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', c.event_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.calls_raw c
    on right(regexp_replace(coalesce(c.other_party_phone, ''), '\D', '', 'g'), 10) = t.phone10
   and abs(extract(epoch from (c.event_at_utc - t.event_at_utc))) <= 120
   and lower(coalesce(c.channel, '')) not in ('call', 'phone')
),
interaction_call_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    i.interaction_id,
    i.channel,
    i.event_at_utc as interaction_event_at_utc,
    i.ingested_at_utc,
    i.contact_id,
    abs(extract(epoch from (i.event_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', i.event_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.interactions i
    on right(regexp_replace(coalesce(i.contact_phone, ''), '\D', '', 'g'), 10) = t.phone10
   and abs(extract(epoch from (i.event_at_utc - t.event_at_utc))) <= 120
   and coalesce(i.is_shadow, false) = false
   and lower(coalesce(i.channel, '')) in ('call', 'phone')
),
interaction_non_call_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    i.interaction_id,
    i.channel,
    i.event_at_utc as interaction_event_at_utc,
    i.ingested_at_utc,
    i.contact_id,
    abs(extract(epoch from (i.event_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', i.event_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.interactions i
    on right(regexp_replace(coalesce(i.contact_phone, ''), '\D', '', 'g'), 10) = t.phone10
   and abs(extract(epoch from (i.event_at_utc - t.event_at_utc))) <= 120
   and coalesce(i.is_shadow, false) = false
   and lower(coalesce(i.channel, '')) not in ('call', 'phone')
),
redline_hits as (
  select
    t.phone_raw,
    t.phone10,
    t.event_at_utc,
    rt.interaction_id,
    rt.interaction_type,
    rt.contact_id,
    rt.event_at_utc as redline_event_at_utc,
    abs(extract(epoch from (rt.event_at_utc - t.event_at_utc)))::numeric as diff_sec,
    (date_trunc('second', rt.event_at_utc) = date_trunc('second', t.event_at_utc)) as exact_match
  from tuples t
  join public.redline_thread rt
    on right(regexp_replace(coalesce(rt.contact_phone, ''), '\D', '', 'g'), 10) = t.phone10
   and lower(coalesce(rt.interaction_type, '')) like 'call%'
   and abs(extract(epoch from (rt.event_at_utc - t.event_at_utc))) <= 120
),
beside_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as beside_count_window_120s,
    bool_or(exact_match) as beside_exact_match,
    min(diff_sec) as beside_min_diff_sec,
    array_remove(array_agg(distinct camber_interaction_id), null) as beside_camber_interaction_ids,
    min(ingested_at_utc) as beside_first_ingested_at_utc,
    max(ingested_at_utc) as beside_last_ingested_at_utc
  from beside_hits
  group by 1, 2, 3
),
calls_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as calls_raw_count_window_120s,
    bool_or(exact_match) as calls_raw_exact_match,
    min(diff_sec) as calls_raw_min_diff_sec,
    array_remove(array_agg(distinct interaction_id), null) as calls_raw_interaction_ids,
    array_remove(array_agg(distinct channel), null) as calls_raw_channels,
    min(ingested_at_utc) as calls_raw_first_ingested_at_utc,
    max(ingested_at_utc) as calls_raw_last_ingested_at_utc
  from calls_call_hits
  group by 1, 2, 3
),
calls_non_call_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as calls_raw_non_call_count_window_120s,
    array_remove(array_agg(distinct interaction_id), null) as calls_raw_non_call_interaction_ids,
    array_remove(array_agg(distinct channel), null) as calls_raw_non_call_channels
  from calls_non_call_hits
  group by 1, 2, 3
),
interactions_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as interactions_count_window_120s,
    bool_or(exact_match) as interactions_exact_match,
    min(diff_sec) as interactions_min_diff_sec,
    array_remove(array_agg(distinct interaction_id), null) as interactions_interaction_ids,
    array_remove(array_agg(distinct channel), null) as interactions_channels,
    array_remove(array_agg(distinct contact_id::text), null) as interaction_contact_ids,
    min(ingested_at_utc) as interactions_first_ingested_at_utc,
    max(ingested_at_utc) as interactions_last_ingested_at_utc
  from interaction_call_hits
  group by 1, 2, 3
),
interactions_non_call_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as interactions_non_call_count_window_120s,
    array_remove(array_agg(distinct interaction_id), null) as interactions_non_call_ids,
    array_remove(array_agg(distinct channel), null) as interactions_non_call_channels
  from interaction_non_call_hits
  group by 1, 2, 3
),
redline_agg as (
  select
    phone_raw,
    phone10,
    event_at_utc,
    count(*) as redline_count_window_120s,
    bool_or(exact_match) as redline_exact_match,
    min(diff_sec) as redline_min_diff_sec,
    array_remove(array_agg(distinct interaction_id::text), null) as redline_interaction_ids,
    array_remove(array_agg(distinct contact_id::text), null) as redline_contact_ids
  from redline_hits
  group by 1, 2, 3
)
select
  t.phone_raw,
  t.event_at_utc,
  coalesce(ca.calls_raw_interaction_ids, '{}'::text[]) as calls_raw_interaction_ids,
  coalesce(cna.calls_raw_non_call_interaction_ids, '{}'::text[]) as calls_raw_non_call_interaction_ids,
  coalesce(ia.interactions_interaction_ids, '{}'::text[]) as interactions_interaction_ids,
  coalesce(ia.interaction_contact_ids, '{}'::text[]) as interaction_contact_ids,
  coalesce(ina.interactions_non_call_ids, '{}'::text[]) as interactions_non_call_ids,
  coalesce(ca.calls_raw_channels, '{}'::text[]) as calls_raw_channels,
  coalesce(cna.calls_raw_non_call_channels, '{}'::text[]) as calls_raw_non_call_channels,
  coalesce(ia.interactions_channels, '{}'::text[]) as interactions_channels,
  coalesce(ina.interactions_non_call_channels, '{}'::text[]) as interactions_non_call_channels,
  least(ca.calls_raw_first_ingested_at_utc, ia.interactions_first_ingested_at_utc) as first_ingested_at_utc,
  greatest(ca.calls_raw_last_ingested_at_utc, ia.interactions_last_ingested_at_utc) as last_ingested_at_utc,
  coalesce(ba.beside_count_window_120s, 0) as beside_count_window_120s,
  coalesce(ca.calls_raw_count_window_120s, 0) as calls_raw_count_window_120s,
  coalesce(cna.calls_raw_non_call_count_window_120s, 0) as calls_raw_non_call_count_window_120s,
  coalesce(ia.interactions_count_window_120s, 0) as interactions_call_count_window_120s,
  coalesce(ina.interactions_non_call_count_window_120s, 0) as interactions_non_call_count_window_120s,
  coalesce(ra.redline_count_window_120s, 0) as redline_count_window_120s,
  coalesce(ba.beside_exact_match, false) as beside_exact_match,
  coalesce(ca.calls_raw_exact_match, false) as calls_raw_exact_match,
  coalesce(ia.interactions_exact_match, false) as interactions_exact_match,
  coalesce(ra.redline_exact_match, false) as redline_exact_match,
  case
    when coalesce(ca.calls_raw_count_window_120s, 0) = 0
      and coalesce(ia.interactions_count_window_120s, 0) = 0
    then 'ingestion_missing'
    when (coalesce(ca.calls_raw_count_window_120s, 0) > 0
       or coalesce(ia.interactions_count_window_120s, 0) > 0)
       and coalesce(ra.redline_count_window_120s, 0) = 0
    then 'view_gap'
    when coalesce(ra.redline_count_window_120s, 0) > 0
    then 'ui_gap'
    else 'unknown'
  end as classification,
  concat_ws(',',
    case when coalesce(ba.beside_count_window_120s, 0) > 0 then 'beside_thread_events' end,
    case when coalesce(ca.calls_raw_count_window_120s, 0) > 0 then 'calls_raw' end,
    case when coalesce(cna.calls_raw_non_call_count_window_120s, 0) > 0 then 'calls_raw(non_call)' end,
    case when coalesce(ia.interactions_count_window_120s, 0) > 0 then 'interactions(call)' end,
    case when coalesce(ina.interactions_non_call_count_window_120s, 0) > 0 then 'interactions(non_call)' end,
    case when coalesce(ra.redline_count_window_120s, 0) > 0 then 'redline_thread' end
  ) as present_in
from tuples t
left join beside_agg ba
  on ba.phone_raw = t.phone_raw
 and ba.event_at_utc = t.event_at_utc
left join calls_agg ca
  on ca.phone_raw = t.phone_raw
 and ca.event_at_utc = t.event_at_utc
left join calls_non_call_agg cna
  on cna.phone_raw = t.phone_raw
 and cna.event_at_utc = t.event_at_utc
left join interactions_agg ia
  on ia.phone_raw = t.phone_raw
 and ia.event_at_utc = t.event_at_utc
left join interactions_non_call_agg ina
  on ina.phone_raw = t.phone_raw
 and ina.event_at_utc = t.event_at_utc
left join redline_agg ra
  on ra.phone_raw = t.phone_raw
 and ra.event_at_utc = t.event_at_utc
order by t.event_at_utc desc, t.phone_raw;

\echo 'Q2) Detail rows for tuples classified as view_gap'
with classified as (
  with input_tuples(phone_raw, event_at_utc) as (
    values
      ('17065559876', '2026-02-27 22:20:30+00'::timestamptz),
      ('16788338072', '2026-02-27 12:51:19+00'::timestamptz),
      ('16784772532', '2026-02-26 20:23:38+00'::timestamptz),
      ('14044017599', '2026-02-26 18:23:23+00'::timestamptz),
      ('17064743770', '2026-02-26 15:52:23+00'::timestamptz),
      ('17709829800', '2026-02-26 14:50:27+00'::timestamptz),
      ('14043727648', '2026-02-25 21:27:27+00'::timestamptz),
      ('17702677027', '2026-02-25 19:45:09+00'::timestamptz),
      ('14048494832', '2026-02-25 16:20:33+00'::timestamptz),
      ('18662989094', '2026-02-25 14:11:58+00'::timestamptz)
  )
  select
    it.phone_raw,
    it.event_at_utc,
    right(regexp_replace(it.phone_raw, '\D', '', 'g'), 10) as phone10
  from input_tuples it
),
gap_base as (
  select
    c.phone_raw,
    c.event_at_utc,
    i.interaction_id,
    i.contact_id,
    i.channel,
    i.ingested_at_utc,
    i.event_at_utc as interactions_event_at_utc
  from classified c
  join public.interactions i
    on right(regexp_replace(coalesce(i.contact_phone, ''), '\D', '', 'g'), 10) = c.phone10
   and abs(extract(epoch from (i.event_at_utc - c.event_at_utc))) <= 120
   and coalesce(i.is_shadow, false) = false
   and lower(coalesce(i.channel, '')) in ('call', 'phone')
)
select
  g.phone_raw,
  g.event_at_utc,
  g.interaction_id,
  g.contact_id,
  g.channel,
  g.ingested_at_utc,
  g.interactions_event_at_utc,
  (select count(*)
   from public.redline_thread rt
   where rt.contact_id = g.contact_id
     and lower(coalesce(rt.interaction_type, '')) like 'call%'
     and abs(extract(epoch from (rt.event_at_utc - g.event_at_utc))) <= 120) as redline_rows_nearby
from gap_base g
order by g.event_at_utc desc, g.phone_raw, g.interaction_id;
