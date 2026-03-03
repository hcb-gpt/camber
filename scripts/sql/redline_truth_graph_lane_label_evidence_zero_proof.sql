-- Template: verifies redline_truth_graph_v1 lane label for missing-evidence scenarios.
-- Edit the interaction_id literal to one where spans exist but evidence events are missing.
-- Run:
--   scripts/query.sh --file scripts/sql/redline_truth_graph_lane_label_evidence_zero_proof.sql

-- DB_PROOF (data-independent):
-- If you cannot find an interaction_id with spans>0 and evidence=0, use this section as
-- the proof gate: verify the function definition contains the correct lane/defect mapping.
with fn as (
  select pg_get_functiondef('public.redline_truth_graph_v1(text)'::regprocedure) as def
)
select
  -- lane_label should prefer 'evidence' when evidence.cnt=0 (after segmentation check)
  (position($$when evidence.cnt = 0 then 'evidence'$$ in lower(fn.def)) > 0) as lane_label_rule_present,
  -- defect type should be missing_evidence when evidence.cnt=0
  (position($$when evidence.cnt = 0 then 'missing_evidence'$$ in lower(fn.def)) > 0) as defect_type_rule_present
from fn;

-- DB_PROOF (data-dependent):
-- Choose an interaction_id where spans exist but evidence events are missing, then validate
-- lane_label='evidence' and primary_defect_type='missing_evidence'.
with params as (
  select 'cll_REPLACE_ME'::text as interaction_id
),
span_counts as (
  select
    p.interaction_id,
    count(*)::int as span_count
  from params p
  left join public.conversation_spans cs
    on cs.interaction_id = p.interaction_id
   and coalesce(cs.is_superseded, false) = false
  group by p.interaction_id
),
evidence_counts as (
  select
    p.interaction_id,
    count(*)::int as evidence_count
  from params p
  left join public.evidence_events ev
    on ev.source_id = p.interaction_id
    or coalesce(ev.metadata->>'interaction_id', '') = p.interaction_id
    or coalesce(ev.metadata->>'call_id', '') = p.interaction_id
  group by p.interaction_id
),
truth as (
  select *
  from public.redline_truth_graph_v1((select interaction_id from params))
)
select
  p.interaction_id,
  s.span_count,
  e.evidence_count,
  t.lane_label,
  t.primary_defect_type,
  (s.span_count > 0 and e.evidence_count = 0) as precondition_spans_gt_0_and_evidence_eq_0,
  (t.lane_label = 'evidence') as lane_label_ok,
  (t.primary_defect_type = 'missing_evidence') as defect_type_ok,
  (
    s.span_count > 0
    and e.evidence_count = 0
    and t.lane_label = 'evidence'
    and t.primary_defect_type = 'missing_evidence'
  ) as proof_pass
from params p
join span_counts s on s.interaction_id = p.interaction_id
join evidence_counts e on e.interaction_id = p.interaction_id
join truth t on t.interaction_id = p.interaction_id;
