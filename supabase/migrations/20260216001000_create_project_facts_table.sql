-- Time-sync evidence layer (v0): project_facts
-- Minimal, provenance-aware, time-stamped facts to support AS_OF vs POST_HOC retrieval.

begin;
create table if not exists public.project_facts (
  id uuid primary key default gen_random_uuid(),

  -- What this fact is about
  project_id uuid not null references public.projects(id) on delete cascade,

  -- When the fact was true vs when it was recorded/observed
  as_of_at timestamptz not null,
  observed_at timestamptz not null,

  -- Flexible payload (start minimal; downstream can impose schemas per fact_kind)
  fact_kind text not null,
  fact_payload jsonb not null,

  -- Provenance pointers (best-effort; not all sources will have all pointers)
  interaction_id text references public.interactions(interaction_id),
  evidence_event_id uuid references public.evidence_events(evidence_event_id),
  source_span_id uuid references public.conversation_spans(id) on delete set null,
  source_char_start integer,
  source_char_end integer,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint project_facts_source_char_bounds_chk check (
    (source_char_start is null and source_char_end is null)
    or
    (
      source_char_start is not null
      and source_char_end is not null
      and source_char_start >= 0
      and source_char_end > source_char_start
    )
  )
);
create index if not exists project_facts_project_asof_idx
  on public.project_facts (project_id, as_of_at desc);
create index if not exists project_facts_asof_idx
  on public.project_facts (as_of_at desc);
create index if not exists project_facts_observed_idx
  on public.project_facts (observed_at desc);
create index if not exists project_facts_kind_idx
  on public.project_facts (fact_kind);
create index if not exists project_facts_interaction_idx
  on public.project_facts (interaction_id);
create index if not exists project_facts_evidence_event_idx
  on public.project_facts (evidence_event_id);
create index if not exists project_facts_span_idx
  on public.project_facts (source_span_id);
comment on table public.project_facts is
  'Time-sync evidence layer (v0): provenance-aware project facts with as_of_at (effective time) and observed_at (recorded time).';
comment on column public.project_facts.as_of_at is
  'When the fact is true/effective. Retrieval for AS_OF uses as_of_at <= t_call.';
comment on column public.project_facts.observed_at is
  'When the fact was recorded/observed (may be after as_of_at).';
comment on column public.project_facts.source_span_id is
  'Optional provenance pointer to a conversation span row (character offsets live in source_char_start/end).';
commit;
