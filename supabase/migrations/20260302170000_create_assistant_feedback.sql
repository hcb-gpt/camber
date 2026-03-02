begin;

create table if not exists public.assistant_feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),

  message_id text not null,
  message_role text not null,
  feedback text not null,
  note text,

  request_id text,
  contact_id uuid,
  project_id uuid,
  prompt text,
  response_excerpt text
);

comment on table public.assistant_feedback is
  'Thumbs up/down + notes for Redline assistant responses (iOS payload: AssistantFeedbackPayload).';

alter table public.assistant_feedback enable row level security;

-- No public policies: writes should go through the assistant-feedback edge function (service role).

create index if not exists assistant_feedback_created_at_idx on public.assistant_feedback(created_at desc);
create index if not exists assistant_feedback_project_id_idx on public.assistant_feedback(project_id);
create index if not exists assistant_feedback_contact_id_idx on public.assistant_feedback(contact_id);
create index if not exists assistant_feedback_request_id_idx on public.assistant_feedback(request_id);

commit;

