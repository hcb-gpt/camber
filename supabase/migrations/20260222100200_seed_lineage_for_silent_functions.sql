-- Seed static lineage edges for functions with zero lineage coverage
-- These are initial seeds; runtime emission will provide live updates
--
-- Functions covered (Step 3 - audit/review):
--   audit-attribution, audit-attribution-reviewer, decision-auditor,
--   review-resolve, auto-review-resolver
-- Functions covered (Step 4 - remaining silent):
--   gt-apply, alias-hygiene, alias-review, alias-scout,
--   embed-facts, evidence-assembler, admin-reseed
--
-- NOTE: financial-receipt-ingest does not exist in the codebase and is excluded.

INSERT INTO public.system_lineage_edges (from_node_id, to_node_id, edge_type, seen_count, last_seen_at_utc)
VALUES
  -- audit-attribution: reads eval_samples + span_attributions, writes attribution_audit_ledger + eval_samples + eval_runs
  ('edge:audit-attribution', 'table:public.eval_samples', 'reads', 1, now()),
  ('edge:audit-attribution', 'table:public.span_attributions', 'reads', 1, now()),
  ('edge:audit-attribution', 'table:public.attribution_audit_ledger', 'writes', 1, now()),
  ('edge:audit-attribution', 'table:public.eval_samples', 'writes', 1, now()),
  ('edge:audit-attribution', 'table:public.eval_runs', 'writes', 1, now()),

  -- audit-attribution-reviewer: pure LLM reviewer, called by audit-attribution
  ('edge:audit-attribution-reviewer', 'edge:audit-attribution', 'called_by', 1, now()),

  -- decision-auditor: reads projects + project_aliases via scan_transcript_for_projects RPC
  ('edge:decision-auditor', 'table:public.projects', 'reads', 1, now()),
  ('edge:decision-auditor', 'table:public.project_aliases', 'reads', 1, now()),

  -- review-resolve: reads review_queue, writes span_attributions + review_queue + override_log + journal_claims
  ('edge:review-resolve', 'table:public.review_queue', 'reads', 1, now()),
  ('edge:review-resolve', 'table:public.span_attributions', 'writes', 1, now()),
  ('edge:review-resolve', 'table:public.review_queue', 'writes', 1, now()),
  ('edge:review-resolve', 'table:public.override_log', 'writes', 1, now()),
  ('edge:review-resolve', 'table:public.journal_claims', 'writes', 1, now()),

  -- auto-review-resolver: reads review_queue, writes review_queue + span_attributions + journal_claims
  ('edge:auto-review-resolver', 'table:public.review_queue', 'reads', 1, now()),
  ('edge:auto-review-resolver', 'table:public.review_queue', 'writes', 1, now()),
  ('edge:auto-review-resolver', 'table:public.span_attributions', 'writes', 1, now()),
  ('edge:auto-review-resolver', 'table:public.journal_claims', 'writes', 1, now()),

  -- gt-apply: reads conversation_spans + projects, writes span_attributions + override_log via RPC
  ('edge:gt-apply', 'table:public.conversation_spans', 'reads', 1, now()),
  ('edge:gt-apply', 'table:public.projects', 'reads', 1, now()),
  ('edge:gt-apply', 'table:public.span_attributions', 'writes', 1, now()),
  ('edge:gt-apply', 'table:public.override_log', 'writes', 1, now()),

  -- alias-hygiene: reads project_aliases + projects + v_project_alias_lookup, writes project_aliases + suggested_aliases
  ('edge:alias-hygiene', 'table:public.project_aliases', 'reads', 1, now()),
  ('edge:alias-hygiene', 'table:public.projects', 'reads', 1, now()),
  ('edge:alias-hygiene', 'view:public.v_project_alias_lookup', 'reads', 1, now()),
  ('edge:alias-hygiene', 'table:public.project_aliases', 'writes', 1, now()),
  ('edge:alias-hygiene', 'table:public.suggested_aliases', 'writes', 1, now()),

  -- alias-review: reads suggested_aliases + projects + v_project_alias_lookup + project_aliases, writes project_aliases + suggested_aliases
  ('edge:alias-review', 'table:public.suggested_aliases', 'reads', 1, now()),
  ('edge:alias-review', 'table:public.projects', 'reads', 1, now()),
  ('edge:alias-review', 'view:public.v_project_alias_lookup', 'reads', 1, now()),
  ('edge:alias-review', 'table:public.project_aliases', 'reads', 1, now()),
  ('edge:alias-review', 'table:public.project_aliases', 'writes', 1, now()),
  ('edge:alias-review', 'table:public.suggested_aliases', 'writes', 1, now()),

  -- alias-scout: reads projects + project_aliases + suggested_aliases + contacts + span_attributions, writes suggested_aliases
  ('edge:alias-scout', 'table:public.projects', 'reads', 1, now()),
  ('edge:alias-scout', 'table:public.project_aliases', 'reads', 1, now()),
  ('edge:alias-scout', 'table:public.suggested_aliases', 'reads', 1, now()),
  ('edge:alias-scout', 'table:public.contacts', 'reads', 1, now()),
  ('edge:alias-scout', 'table:public.span_attributions', 'reads', 1, now()),
  ('edge:alias-scout', 'table:public.suggested_aliases', 'writes', 1, now()),

  -- embed-facts: reads project_facts (null embeddings), writes project_facts (embedding update)
  ('edge:embed-facts', 'table:public.project_facts', 'reads', 1, now()),
  ('edge:embed-facts', 'table:public.project_facts', 'writes', 1, now()),

  -- evidence-assembler: read-only, many tables for evidence gathering
  ('edge:evidence-assembler', 'view:public.v_project_alias_lookup', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.project_contacts', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.correspondent_project_affinity', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.journal_claims', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.journal_open_loops', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.call_chains', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.span_attributions', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.project_facts', 'reads', 1, now()),
  ('edge:evidence-assembler', 'table:public.contact_fanout', 'reads', 1, now()),
  ('edge:evidence-assembler', 'edge:gmail-context-lookup', 'calls', 1, now()),

  -- admin-reseed: reads many tables, writes conversation_spans + span_attributions + override_log + review_queue, calls segment-llm + context-assembly + ai-router + striking-detect + journal-extract
  ('edge:admin-reseed', 'table:public.override_log', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.interactions', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.conversation_spans', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.span_attributions', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.transcripts_comparison', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.calls_raw', 'reads', 1, now()),
  ('edge:admin-reseed', 'table:public.conversation_spans', 'writes', 1, now()),
  ('edge:admin-reseed', 'table:public.span_attributions', 'writes', 1, now()),
  ('edge:admin-reseed', 'table:public.override_log', 'writes', 1, now()),
  ('edge:admin-reseed', 'table:public.review_queue', 'writes', 1, now()),
  ('edge:admin-reseed', 'edge:segment-llm', 'calls', 1, now()),
  ('edge:admin-reseed', 'edge:context-assembly', 'calls', 1, now()),
  ('edge:admin-reseed', 'edge:ai-router', 'calls', 1, now()),
  ('edge:admin-reseed', 'edge:striking-detect', 'calls', 1, now()),
  ('edge:admin-reseed', 'edge:journal-extract', 'calls', 1, now())
ON CONFLICT (from_node_id, to_node_id, edge_type) DO UPDATE SET
  seen_count = system_lineage_edges.seen_count + 1,
  last_seen_at_utc = now();
