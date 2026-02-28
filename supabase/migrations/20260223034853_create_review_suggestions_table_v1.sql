create table if not exists public.review_suggestions (
  id uuid primary key default gen_random_uuid(),
  review_queue_id uuid not null references public.review_queue(id) on delete cascade,
  span_id uuid null,
  interaction_id text null,
  module text null,
  suggested_action text not null, -- e.g. assign|review|dismiss
  suggested_project_id uuid null,
  suggestion_confidence numeric null,
  rationale text null,
  model_id text null,
  prompt_version text null,
  created_at timestamptz not null default now(),
  unique (review_queue_id)
);

create index if not exists idx_review_suggestions_created_at on public.review_suggestions(created_at desc);
create index if not exists idx_review_suggestions_action on public.review_suggestions(suggested_action);
;
