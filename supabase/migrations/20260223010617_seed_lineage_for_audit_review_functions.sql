
-- Seed lineage edges for the 5 audit/review functions that were instrumented
-- with runtime emission but need static seeds for immediate visibility.

INSERT INTO public.system_lineage_edges (from_node_id, to_node_id, edge_type, seen_count, last_seen_at_utc, meta)
VALUES
  -- audit-attribution: reads eval_samples + span_attributions, writes eval_samples + attribution_audit_ledger + eval_runs
  ('edge:audit-attribution', 'table:public.eval_samples', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:audit-attribution', 'table:public.span_attributions', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:audit-attribution', 'table:public.attribution_audit_ledger', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:audit-attribution', 'table:public.eval_samples', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:audit-attribution', 'table:public.eval_runs', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),

  -- audit-attribution-reviewer: stateless LLM reviewer, called by audit pipeline
  ('edge:audit-attribution-reviewer', 'edge:audit-attribution', 'called_by', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),

  -- decision-auditor: reads projects + project_aliases via scan_transcript_for_projects RPC
  ('edge:decision-auditor', 'table:public.projects', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:decision-auditor', 'table:public.project_aliases', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),

  -- review-resolve: reads review_queue, writes span_attributions + review_queue + override_log + journal_claims
  ('edge:review-resolve', 'table:public.review_queue', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:review-resolve', 'table:public.span_attributions', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:review-resolve', 'table:public.review_queue', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:review-resolve', 'table:public.override_log', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:review-resolve', 'table:public.journal_claims', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),

  -- auto-review-resolver: reads review_queue, writes review_queue + span_attributions + journal_claims
  ('edge:auto-review-resolver', 'table:public.review_queue', 'reads', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:auto-review-resolver', 'table:public.review_queue', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:auto-review-resolver', 'table:public.span_attributions', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}'),
  ('edge:auto-review-resolver', 'table:public.journal_claims', 'writes', 1, now(),
    '{"seeded": true, "seed_source": "trust_primitives_audit_review_20260223"}')
ON CONFLICT (from_node_id, to_node_id, edge_type) DO UPDATE SET
  seen_count = system_lineage_edges.seen_count + 1,
  last_seen_at_utc = now(),
  meta = coalesce(system_lineage_edges.meta, '{}'::jsonb)
    || coalesce(excluded.meta, '{}'::jsonb);
;
