-- Stopline metric view: anchored vs unanchored assignment rates.
-- Definition aligns with stopline policy:
-- - Anchored assignment = transcript anchor pointers OR doc provenance pointers.
-- - Unanchored assignment = assign decision without either evidence form.

create or replace view public.v_metrics_attribution_anchor_quality as
with latest_attribution as (
  select distinct on (sa.span_id)
    sa.span_id,
    cs.interaction_id,
    coalesce(sa.applied_project_id, sa.project_id) as assigned_project_id,
    sa.decision,
    sa.matched_terms,
    sa.match_positions,
    coalesce(sa.applied_at_utc, sa.attributed_at, now()) as decision_ts_utc
  from public.span_attributions sa
  join public.conversation_spans cs
    on cs.id = sa.span_id
  where cs.is_superseded = false
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at, now()) desc, sa.id desc
),
assign_rows as (
  select
    la.*,
    coalesce(array_length(la.matched_terms, 1), 0) as matched_terms_count,
    jsonb_array_length(coalesce(la.match_positions, '[]'::jsonb)) as match_positions_count,
    exists (
      select 1
      from jsonb_array_elements(coalesce(la.match_positions, '[]'::jsonb)) as mp
      where coalesce(mp->>'source', '') = 'project_fact'
        and coalesce(mp->>'evidence_event_id', '') <> ''
    ) as has_doc_provenance
  from latest_attribution la
  where la.decision = 'assign'
    and la.assigned_project_id is not null
    and la.decision_ts_utc >= now() - interval '24 hours'
)
select
  now() as measured_at_utc,
  count(*)::bigint as total_assignments_24h,
  count(*) filter (
    where (matched_terms_count > 0 and match_positions_count > 0) or has_doc_provenance
  )::bigint as anchored_assignments_24h,
  count(*) filter (
    where not ((matched_terms_count > 0 and match_positions_count > 0) or has_doc_provenance)
  )::bigint as unanchored_assignments_24h,
  case
    when count(*) = 0 then 0::numeric
    else round(
      (
        count(*) filter (
          where (matched_terms_count > 0 and match_positions_count > 0) or has_doc_provenance
        )::numeric / count(*)::numeric
      ),
      4
    )
  end as anchored_assign_rate,
  case
    when count(*) = 0 then 0::numeric
    else round(
      (
        count(*) filter (
          where not ((matched_terms_count > 0 and match_positions_count > 0) or has_doc_provenance)
        )::numeric / count(*)::numeric
      ),
      4
    )
  end as unanchored_assign_rate
from assign_rows;

comment on view public.v_metrics_attribution_anchor_quality is
  'Stopline attribution quality metrics over the last 24h: anchored_assign_rate and unanchored_assign_rate.';
