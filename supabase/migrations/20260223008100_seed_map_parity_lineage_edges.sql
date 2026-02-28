begin;
-- Seed known producer edges that are valid but may be absent from runtime evidence
-- snapshots at query time. This improves map parity and orphan-table diagnostics.
with seeded_edges as (
  select *
  from (
    values
      (
        'edge:zapier-sms-ingest'::text,
        'table:public.sms_messages'::text,
        'writes'::text
      ),
      (
        'edge:brief-serve'::text,
        'table:public.brief_deliveries'::text,
        'writes'::text
      ),
      (
        'edge:brief-serve'::text,
        'table:public.brief_events'::text,
        'writes'::text
      ),
      (
        'edge:brief-serve'::text,
        'table:public.scheduler_items'::text,
        'writes'::text
      ),
      (
        'edge:journal-consolidate'::text,
        'table:public.journal_review_queue'::text,
        'writes'::text
      ),
      (
        'fn:public.promote_journal_claims_to_belief(p_run_id uuid)'::text,
        'table:public.belief_claims'::text,
        'writes'::text
      ),
      (
        'fn:public.promote_journal_claims_to_belief(p_run_id uuid)'::text,
        'table:public.claim_pointers'::text,
        'writes'::text
      ),
      (
        'fn:public.promote_journal_claims_to_belief(p_run_id uuid)'::text,
        'table:public.promotion_log'::text,
        'writes'::text
      ),
      (
        'fn:public.promote_journal_claims_to_belief(p_run_id uuid)'::text,
        'table:public.journal_review_queue'::text,
        'writes'::text
      ),
      (
        'fn:public.run_auto_review_resolver(p_high_conf numeric, p_low_conf numeric, p_limit integer, p_actor text, p_dry_run boolean)'::text,
        'table:public.review_audit'::text,
        'writes'::text
      ),
      (
        'fn:public.run_auto_review_resolver(p_high_conf numeric, p_low_conf numeric, p_limit integer, p_actor text, p_dry_run boolean)'::text,
        'table:public.review_queue'::text,
        'writes'::text
      )
  ) as t(from_node_id, to_node_id, edge_type)
)
insert into public.system_lineage_edges (
  from_node_id,
  to_node_id,
  edge_type,
  first_seen_at_utc,
  last_seen_at_utc,
  seen_count,
  meta
)
select
  from_node_id,
  to_node_id,
  edge_type,
  now(),
  now(),
  1,
  jsonb_build_object(
    'seeded', true,
    'seed_source', 'map_parity_20260222',
    'seed_note', 'Bootstrapped lineage edge for stable map parity coverage'
  )
from seeded_edges
on conflict (from_node_id, to_node_id, edge_type)
do update set
  last_seen_at_utc = greatest(public.system_lineage_edges.last_seen_at_utc, excluded.last_seen_at_utc),
  seen_count = greatest(public.system_lineage_edges.seen_count, 1),
  meta = coalesce(public.system_lineage_edges.meta, '{}'::jsonb)
    || coalesce(excluded.meta, '{}'::jsonb);
commit;
