-- Backfill candidates_snapshot for recent attributions using interactions.candidate_projects
-- Safe: only fills where candidates_snapshot is NULL or empty array/object.

with upd as (
  update public.span_attributions sa
  set candidates_snapshot = (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'project_id', elem->>'id',
          'project_name', elem->>'name',
          'confidence', coalesce((elem->>'confidence')::numeric, null),
          'score', coalesce((elem->>'score')::numeric, null),
          'matches', coalesce((elem->>'matches')::int, null),
          'sources', elem->'sources',
          'weak_only', coalesce((elem->>'weak_only')::boolean, null)
        )
        order by coalesce((elem->>'confidence')::numeric, 0) desc, coalesce((elem->>'score')::numeric, 0) desc
      ),
      '[]'::jsonb
    )
    from public.conversation_spans cs
    join public.interactions i on i.interaction_id = cs.interaction_id
    cross join lateral jsonb_array_elements(coalesce(i.candidate_projects, '[]'::jsonb)) elem
    where cs.id = sa.span_id
  )
  where sa.attributed_at >= (now() - interval '24 hours')
    and (
      sa.candidates_snapshot is null
      or sa.candidates_snapshot = '[]'::jsonb
      or sa.candidates_snapshot = '{}'::jsonb
    )
    and exists (
      select 1
      from public.conversation_spans cs2
      join public.interactions i2 on i2.interaction_id = cs2.interaction_id
      where cs2.id = sa.span_id
        and i2.candidate_projects is not null
        and jsonb_array_length(i2.candidate_projects) > 0
    )
  returning sa.id
)
select count(*) as updated_rows from upd;;
