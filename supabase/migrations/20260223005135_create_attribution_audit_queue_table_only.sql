create table if not exists public.attribution_audit_queue (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  last_seen_at_utc timestamptz not null default now(),

  span_attribution_id uuid not null references public.span_attributions(id) on delete cascade,
  span_id uuid not null references public.conversation_spans(id) on delete cascade,
  interaction_id text not null,

  assigned_project_id uuid null references public.projects(id),
  assigned_confidence numeric null,
  attribution_source text null,
  evidence_tier int null,

  evidence_event_id uuid null references public.evidence_events(evidence_event_id),
  t_call_utc timestamptz null,
  asof_mode text not null default 'KNOWN_AS_OF' check (asof_mode in ('KNOWN_AS_OF','TRUTH_AS_OF')),
  same_call_excluded boolean not null default true,

  anchors jsonb not null default '[]'::jsonb,

  packet_hash text not null,

  status text not null default 'pending' check (status in ('pending','processing','done','error')),
  claimed_by text null,
  claimed_at_utc timestamptz null,
  completed_at_utc timestamptz null,
  error_text text null,

  created_at timestamptz not null default now()
);

create index if not exists idx_attrib_audit_queue_status_created
  on public.attribution_audit_queue (status, created_at desc);

create index if not exists idx_attrib_audit_queue_interaction
  on public.attribution_audit_queue (interaction_id);

comment on table public.attribution_audit_queue is
'Queue of attribution audit samples (staging). Stores pointers to evidence_event + structured anchors; impartial reviewer writes final verdict to attribution_audit_ledger.';
;
