-- prod_attrib_audit_pending_packets.sql
--
-- Purpose:
-- - Build base64-encoded reviewer packets for unreviewed samples in latest
--   prod_attrib_audit run.
--
-- Output columns:
-- - eval_run_id
-- - eval_run_name
-- - eval_sample_id
-- - sample_rank
-- - packet_b64
--
-- Usage:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -A -t -F $'\t' \
--     -v sample_limit=30 \
--     -f scripts/sql/prod_attrib_audit_pending_packets.sql

\if :{?sample_limit}
\else
\set sample_limit 30
\endif

\if :{?eval_run_id}
\else
\set eval_run_id ''
\endif

\if :{?exclude_eval_run_id}
\else
\set exclude_eval_run_id ''
\endif

with run_candidates as (
  select
    er.id,
    er.name,
    er.created_at,
    (
      select count(*)
      from public.eval_samples es
      where es.eval_run_id = er.id
    ) as sample_count
  from public.eval_runs er
  where er.name like 'prod_attrib_audit_%'
),
target_run as (
  select
    rc.id,
    rc.name,
    rc.created_at
  from run_candidates rc
  where (
      nullif(:'eval_run_id', '') is null
      or rc.id = nullif(:'eval_run_id', '')::uuid
    )
    and (
      nullif(:'exclude_eval_run_id', '') is null
      or rc.id <> nullif(:'exclude_eval_run_id', '')::uuid
    )
  order by
    case when rc.sample_count > 0 then 0 else 1 end,
    rc.created_at desc
  limit 1
),
latest_attribution as (
  select distinct on (sa.span_id)
    sa.id as span_attribution_id,
    sa.span_id,
    coalesce(sa.applied_project_id, sa.project_id) as assigned_project_id,
    sa.attribution_source,
    sa.decision,
    sa.confidence,
    sa.evidence_tier,
    sa.attributed_at
  from public.span_attributions sa
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
sample_base as (
  select
    es.id as eval_sample_id,
    es.eval_run_id,
    es.sample_rank,
    es.reviewer_completed_at,
    es.interaction_id,
    i.contact_id,
    es.span_id,
    cs.span_index,
    cs.char_start,
    cs.char_end,
    cs.transcript_segment,
    coalesce(i.event_at_utc, i.ingested_at_utc, cs.created_at) as call_at_utc,
    la.span_attribution_id,
    la.assigned_project_id,
    la.attribution_source,
    la.decision as assigned_decision,
    la.confidence as assigned_confidence,
    la.evidence_tier as assigned_evidence_tier
  from public.eval_samples es
  join target_run tr on tr.id = es.eval_run_id
  join public.conversation_spans cs on cs.id = es.span_id
  join public.interactions i on i.interaction_id = es.interaction_id
  left join latest_attribution la on la.span_id = es.span_id
),
pool_mode as (
  select
    exists (
      select 1
      from sample_base
      where reviewer_completed_at is null
    ) as use_pending_only
),
scored_base as (
  select
    sb.*,
    coalesce(comp.competitor_project_count, 0) as competitor_project_count
  from sample_base sb
  left join lateral (
    select
      count(distinct pf_alt.project_id)::int as competitor_project_count
    from public.interactions i_alt
    join public.project_facts pf_alt on pf_alt.interaction_id = i_alt.interaction_id
    where sb.contact_id is not null
      and i_alt.contact_id = sb.contact_id
      and i_alt.interaction_id <> sb.interaction_id
      and pf_alt.project_id is not null
      and (sb.assigned_project_id is null or pf_alt.project_id <> sb.assigned_project_id)
      and pf_alt.as_of_at <= sb.call_at_utc
      and coalesce(pf_alt.observed_at, pf_alt.as_of_at, pf_alt.created_at) <= sb.call_at_utc
      and pf_alt.evidence_event_id is not null
  ) comp on true
),
selected_base as (
  select sb.*
  from scored_base sb
  cross join pool_mode pm
  where
    (pm.use_pending_only and sb.reviewer_completed_at is null)
    or (not pm.use_pending_only)
  order by
    (sb.competitor_project_count > 0) desc,
    sb.competitor_project_count desc,
    sb.sample_rank
  limit :sample_limit
),
packet_rows as (
  select
    sb.eval_run_id,
    sb.eval_sample_id,
    sb.sample_rank,
    jsonb_build_object(
      'eval_sample_id', sb.eval_sample_id,
      'interaction_id', sb.interaction_id,
      'span_id', sb.span_id,
      'span_attribution_id', sb.span_attribution_id,
      'assigned_project_id', sb.assigned_project_id,
      'assigned_decision', sb.assigned_decision,
      'assigned_confidence', sb.assigned_confidence,
      'assigned_evidence_tier', sb.assigned_evidence_tier,
      'attribution_source', sb.attribution_source,
      'call_at_utc', sb.call_at_utc,
      'known_as_of_mode', 'KNOWN_AS_OF',
      'same_call_excluded', true,
      'evidence_event_ids', to_jsonb(coalesce(ce.call_evidence_event_ids, '{}'::uuid[])),
      'pointer_quality_violation', (coalesce(cardinality(ce.call_evidence_event_ids), 0) = 0),
      'failure_mode_tags',
      case
        when coalesce(cardinality(ce.call_evidence_event_ids), 0) = 0
          then jsonb_build_array('insufficient_provenance_pointer_quality')
        else '[]'::jsonb
      end,
      'competing_project_count', sb.competitor_project_count,
      'candidate_project_ids', coalesce(cand.candidate_project_ids, '[]'::jsonb),
      'span_bounds', jsonb_build_object(
        'span_index', sb.span_index,
        'char_start', sb.char_start,
        'char_end', sb.char_end
      ),
      'transcript_segment', sb.transcript_segment,
      'evidence_events', coalesce(ee.evidence_events, '[]'::jsonb),
      'claim_pointers', coalesce(cp.claim_pointers, '[]'::jsonb),
      'as_of_project_context', coalesce(pf.project_facts_asof, '[]'::jsonb),
      'competing_candidates', coalesce(cc.competing_candidates, '[]'::jsonb),
      'guardrails', jsonb_build_object(
        'known_as_of_enforced', true,
        'same_call_excluded', true,
        'evidence_event_count', coalesce(jsonb_array_length(ee.evidence_events), 0),
        'pointer_quality_violation', (coalesce(cardinality(ce.call_evidence_event_ids), 0) = 0),
        'claim_pointer_count', coalesce(jsonb_array_length(cp.claim_pointers), 0),
        'project_context_count', coalesce(jsonb_array_length(pf.project_facts_asof), 0),
        'provenance_ready', (coalesce(jsonb_array_length(ee.evidence_events), 0) > 0)
      )
    ) as audit_packet_json
  from selected_base sb
  left join lateral (
    select
      jsonb_agg(
        jsonb_build_object(
          'evidence_event_id', e.evidence_event_id,
          'occurred_at_utc', e.occurred_at_utc,
          'source_type', e.source_type,
          'source_id', e.source_id,
          'payload_ref', e.payload_ref,
          'integrity_hash', e.integrity_hash,
          'metadata', e.metadata
        )
        order by e.occurred_at_utc desc
      ) as evidence_events
    from (
      select
        ee.evidence_event_id,
        ee.occurred_at_utc,
        ee.source_type,
        ee.source_id,
        ee.payload_ref,
        ee.integrity_hash,
        ee.metadata
      from public.evidence_events ee
      where ee.source_type = 'call'
        and ee.source_id = sb.interaction_id
      order by ee.occurred_at_utc desc
      limit 8
    ) e
  ) ee on true
  left join lateral (
    select
      coalesce(
        array_agg(e.evidence_event_id order by e.occurred_at_utc desc nulls last, e.created_at desc),
        '{}'::uuid[]
      ) as call_evidence_event_ids
    from (
      select
        ee.evidence_event_id,
        ee.occurred_at_utc,
        ee.created_at
      from public.evidence_events ee
      where ee.source_type = 'call'
        and ee.source_id = sb.interaction_id
      order by ee.occurred_at_utc desc nulls last, ee.created_at desc
      limit 100
    ) e
  ) ce on true
  left join lateral (
    select
      jsonb_agg(
        jsonb_build_object(
          'claim_pointer_id', c.id,
          'claim_id', c.claim_id,
          'claim_project_id', c.claim_project_id,
          'source_type', c.source_type,
          'source_id', c.source_id,
          'char_start', c.char_start,
          'char_end', c.char_end,
          'span_hash', c.span_hash,
          'span_text', c.span_text,
          'evidence_event_id', c.evidence_event_id,
          'created_at', c.created_at
        )
        order by c.created_at desc
      ) as claim_pointers
    from (
      select
        cp.id,
        cp.claim_id,
        bc.project_id as claim_project_id,
        cp.source_type,
        cp.source_id,
        cp.char_start,
        cp.char_end,
        cp.span_hash,
        cp.span_text,
        cp.evidence_event_id,
        cp.created_at
      from public.claim_pointers cp
      left join public.belief_claims bc on bc.id = cp.claim_id
      where cp.source_id = sb.interaction_id
      order by cp.created_at desc
      limit 8
    ) c
  ) cp on true
  left join lateral (
    select
      coalesce(
        jsonb_agg(
          candidate.project_id
          order by candidate.priority, candidate.last_seen_at desc nulls last
        ),
        '[]'::jsonb
      ) as candidate_project_ids
    from (
      select
        sb.assigned_project_id as project_id,
        0::int as priority,
        sb.call_at_utc as last_seen_at
      where sb.assigned_project_id is not null

      union all

      select
        alt.project_id,
        1::int as priority,
        alt.last_seen_at
      from (
        select
          pf_alt.project_id,
          max(coalesce(i_alt.event_at_utc, i_alt.ingested_at_utc)) as last_seen_at
        from public.interactions i_alt
        join public.project_facts pf_alt on pf_alt.interaction_id = i_alt.interaction_id
        where sb.contact_id is not null
          and i_alt.contact_id = sb.contact_id
          and i_alt.interaction_id <> sb.interaction_id
          and pf_alt.project_id is not null
          and (sb.assigned_project_id is null or pf_alt.project_id <> sb.assigned_project_id)
          and pf_alt.as_of_at <= sb.call_at_utc
          and coalesce(pf_alt.observed_at, pf_alt.as_of_at, pf_alt.created_at) <= sb.call_at_utc
          and pf_alt.evidence_event_id is not null
        group by pf_alt.project_id
        order by last_seen_at desc nulls last
        limit 3
      ) alt
    ) candidate
  ) cand on true
  left join lateral (
    select
      jsonb_agg(
        jsonb_build_object(
          'project_fact_id', f.id,
          'project_id', f.project_id,
          'fact_kind', f.fact_kind,
          'as_of_at', f.as_of_at,
          'observed_at', f.observed_at,
          'fact_payload', f.fact_payload,
          'evidence_event_id', f.evidence_event_id,
          'source_span_id', f.source_span_id,
          'source_char_start', f.source_char_start,
          'source_char_end', f.source_char_end,
          'interaction_id', f.interaction_id
        )
        order by f.as_of_at desc nulls last, f.created_at desc
      ) as project_facts_asof
    from (
      select
        pf.id,
        pf.project_id,
        pf.fact_kind,
        pf.as_of_at,
        pf.observed_at,
        pf.fact_payload,
        pf.evidence_event_id,
        pf.source_span_id,
        pf.source_char_start,
        pf.source_char_end,
        pf.interaction_id,
        pf.created_at
      from public.project_facts pf
      where pf.project_id in (
        select candidate.project_id_txt::uuid
        from jsonb_array_elements_text(coalesce(cand.candidate_project_ids, '[]'::jsonb)) as candidate(project_id_txt)
        where candidate.project_id_txt ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
        and pf.as_of_at <= sb.call_at_utc
        and coalesce(pf.observed_at, pf.as_of_at, pf.created_at) <= sb.call_at_utc
        and (pf.interaction_id is null or pf.interaction_id <> sb.interaction_id)
        and pf.evidence_event_id is not null
        and not (
          pf.evidence_event_id = any(coalesce(ce.call_evidence_event_ids, '{}'::uuid[]))
        )
      order by
        case when pf.project_id = sb.assigned_project_id then 0 else 1 end,
        pf.as_of_at desc nulls last,
        pf.created_at desc
      limit 40
    ) f
  ) pf on true
  left join lateral (
    select
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'project_id', p.id,
            'project_name', p.name
          )
          order by p.name
        ),
        '[]'::jsonb
      ) as competing_candidates
    from jsonb_array_elements_text(coalesce(cand.candidate_project_ids, '[]'::jsonb)) as candidate(project_id_txt)
    join public.projects p
      on p.id::text = candidate.project_id_txt
  ) cc on true
)
select
  tr.id as eval_run_id,
  tr.name as eval_run_name,
  pr.eval_sample_id,
  pr.sample_rank,
  replace(encode(convert_to(pr.audit_packet_json::text, 'UTF8'), 'base64'), E'\n', '') as packet_b64
from packet_rows pr
join target_run tr on tr.id = pr.eval_run_id
order by pr.sample_rank;
