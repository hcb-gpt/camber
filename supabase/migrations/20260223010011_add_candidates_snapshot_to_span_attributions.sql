
alter table public.span_attributions
  add column if not exists candidates_snapshot jsonb;

comment on column public.span_attributions.candidates_snapshot is
  'Snapshot of ranked candidates from context-assembly at attribution time. Array of {project_id, project_name, rrf_score, evidence_sources}.';
;
