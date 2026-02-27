-- PR-4 reconciliation fix: align with live schema
-- Fixes from DATA_STRAT_20260130T0822Z_pr4_review_queue_migration_reconciled.sql
--
-- Delta from initial pr4 migration:
-- - Add updated_at column + trigger (missing)
-- - Add reason_codes column (coexists with reasons)
-- - Fix view: use attributed_at, coalesce reason_codes/reasons
-- - Use to_jsonb() for defensive column access

begin;
-- 0) Helper updated_at trigger func (idempotent)
create or replace function public.tg_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;
-- 1) Add missing columns to review_queue
alter table public.review_queue add column if not exists updated_at timestamptz;
alter table public.review_queue add column if not exists reason_codes text[];
-- Ensure updated_at has a value for existing rows
update public.review_queue
set updated_at = coalesce(updated_at, created_at, now())
where updated_at is null;
-- 2) Trigger for updated_at
drop trigger if exists trg_review_queue_updated_at on public.review_queue;
create trigger trg_review_queue_updated_at
before update on public.review_queue
for each row execute procedure public.tg_set_updated_at();
-- 3) Replace view with reconciled version
-- Uses attributed_at (actual column), coalesces reason_codes/reasons,
-- and uses to_jsonb() for defensive column access
create or replace view public.v_review_queue_spans as
with latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    to_jsonb(sa) as attr_json,
    sa.attributed_at as attributed_at
  from public.span_attributions sa
  order by sa.span_id, sa.attributed_at desc nulls last
)
select
  rq.id as review_queue_id,
  rq.status as review_status,

  -- prefer reason_codes, fall back to legacy reasons
  coalesce(rq.reason_codes, rq.reasons) as reason_codes,

  rq.created_at as review_created_at,
  rq.updated_at as review_updated_at,
  rq.resolved_at as review_resolved_at,

  rq.span_id as span_id,
  rq.interaction_id as interaction_id,

  -- Span fields (best-effort via jsonb)
  cs.id as span_row_id,
  nullif(to_jsonb(cs)->>'start_ms','')::bigint as span_start_ms,
  nullif(to_jsonb(cs)->>'end_ms','')::bigint as span_end_ms,
  left(
    coalesce(
      to_jsonb(cs)->>'transcript_segment',
      to_jsonb(cs)->>'transcript_text',
      to_jsonb(cs)->>'text',
      rq.context_payload->>'transcript_snippet',
      ''
    ),
    600
  ) as transcript_snippet,

  -- Interaction fields (best-effort via jsonb)
  i.id as interaction_row_id,
  coalesce(to_jsonb(i)->>'channel', 'unknown') as channel,
  coalesce(
    to_jsonb(i)->>'event_at_utc',
    to_jsonb(i)->>'occurred_at_utc',
    to_jsonb(i)->>'created_at'
  ) as interaction_time,

  -- Latest attribution (raw json + extracted scalars)
  la.attributed_at as attribution_at_utc,
  la.attr_json as attribution_json,
  la.attr_json->>'decision' as decision,
  nullif(la.attr_json->>'confidence','')::numeric as confidence,
  la.attr_json->>'project_id' as predicted_project_id,
  la.attr_json->>'applied_project_id' as applied_project_id,
  la.attr_json->>'attribution_lock' as attribution_lock,
  (la.attr_json->>'needs_review')::boolean as needs_review

from public.review_queue rq
left join public.conversation_spans cs
  on cs.id = rq.span_id
left join public.interactions i
  on i.id = coalesce(rq.interaction_id, (to_jsonb(cs)->>'interaction_id')::uuid)
left join latest_attr la
  on la.span_id = rq.span_id;
comment on view public.v_review_queue_spans is
  'Product surface for review queue. Joins review items to spans, attributions, and interactions. Uses attributed_at from span_attributions and coalesces reason_codes/reasons for back-compat.';
commit;
