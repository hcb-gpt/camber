-- Seed runtime lineage edges for top-3 orphan targets from 2026-02-22 parity scan.
-- Scope intentionally limited to:
--   - public.journal_review_queue
--   - public.claim_pointers
--   - public.review_audit

begin;
with seeded_edges as (
  select *
  from (
    values
      (
        'edge:journal-consolidate'::text,
        'table:public.journal_review_queue'::text,
        'writes'::text,
        jsonb_build_object(
          'seeded', true,
          'seed_source', 'orphan_lineage_top3_20260222',
          'writer_evidence', 'supabase/functions/journal-consolidate/index.ts:403'
        )
      ),
      (
        'fn:public.promote_journal_claims_to_belief(p_run_id uuid)'::text,
        'table:public.claim_pointers'::text,
        'writes'::text,
        jsonb_build_object(
          'seeded', true,
          'seed_source', 'orphan_lineage_top3_20260222',
          'writer_evidence', 'supabase/migrations/20260121045416_update_promote_function_to_use_decide_lane.sql:124'
        )
      ),
      (
        'fn:public.run_auto_review_resolver(p_high_conf numeric, p_low_conf numeric, p_limit integer, p_actor text, p_dry_run boolean)'::text,
        'table:public.review_audit'::text,
        'writes'::text,
        jsonb_build_object(
          'seeded', true,
          'seed_source', 'orphan_lineage_top3_20260222',
          'writer_evidence', 'supabase/migrations/20260222051200_create_auto_review_resolver.sql:216'
        )
      )
  ) as t(from_node_id, to_node_id, edge_type, meta)
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
  meta
from seeded_edges
on conflict (from_node_id, to_node_id, edge_type)
do update set
  last_seen_at_utc = greatest(public.system_lineage_edges.last_seen_at_utc, excluded.last_seen_at_utc),
  seen_count = greatest(public.system_lineage_edges.seen_count, 1),
  meta = coalesce(public.system_lineage_edges.meta, '{}'::jsonb)
    || coalesce(excluded.meta, '{}'::jsonb);
commit;
