-- Provides an operator/audit-friendly candidate snapshot even when pipeline doesn't populate candidates_snapshot.
-- Priority order:
-- 1) candidates_snapshot when non-null and non-empty array
-- 2) top_candidates when non-null and non-empty array (truncated but better than null)
-- 3) empty array

create or replace view public.v_span_candidates_snapshot_effective as
select
  sa.span_id,
  cs.interaction_id,
  cs.span_index,
  sa.attributed_at,
  case
    when sa.candidates_snapshot is not null and sa.candidates_snapshot <> '[]'::jsonb then sa.candidates_snapshot
    when sa.top_candidates is not null and sa.top_candidates <> '[]'::jsonb then sa.top_candidates
    else '[]'::jsonb
  end as candidates_effective,
  case
    when sa.candidates_snapshot is not null and sa.candidates_snapshot <> '[]'::jsonb then 'candidates_snapshot'
    when sa.top_candidates is not null and sa.top_candidates <> '[]'::jsonb then 'top_candidates'
    when sa.candidates_snapshot is not null and sa.candidates_snapshot = '[]'::jsonb then 'candidates_snapshot_empty'
    else 'none'
  end as candidates_source,
  sa.candidate_count,
  jsonb_array_length(
    case
      when sa.candidates_snapshot is not null and sa.candidates_snapshot <> '[]'::jsonb then sa.candidates_snapshot
      when sa.top_candidates is not null and sa.top_candidates <> '[]'::jsonb then sa.top_candidates
      else '[]'::jsonb
    end
  ) as candidates_len,
  sa.attribution_source,
  sa.decision,
  sa.confidence
from public.span_attributions sa
join public.conversation_spans cs on cs.id = sa.span_id;
;
