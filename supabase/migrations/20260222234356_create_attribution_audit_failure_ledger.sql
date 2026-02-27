-- Attribution audit failure ledger + regression manifest

-- 1) Append-only, idempotent ledger of attribution spotchecks.
--    Each row ties a reviewer verdict to the exact attribution decision + evidence packet.

create table if not exists public.attribution_audit_ledger (
  id uuid primary key default gen_random_uuid(),

  -- Idempotency / replay safety
  dedupe_key text not null unique, -- deterministic hash of (span_attribution_id, reviewer_model, reviewer_prompt_version, packet_hash)
  hit_count int not null default 1,
  first_seen_at_utc timestamptz not null default now(),
  last_seen_at_utc timestamptz not null default now(),

  -- Trace to the production decision being audited
  span_attribution_id uuid not null references public.span_attributions(id) on delete cascade,
  span_id uuid not null references public.conversation_spans(id) on delete cascade,
  interaction_id text not null,

  assigned_project_id uuid null references public.projects(id),
  assigned_decision text null check (assigned_decision in ('assign','review','none')),
  assigned_confidence numeric null check (assigned_confidence >= 0 and assigned_confidence <= 1),
  attribution_source text null,
  evidence_tier int null,

  -- Evidence packet identity (NOT narrative)
  t_call_utc timestamptz not null,
  asof_mode text not null default 'KNOWN_AS_OF' check (asof_mode in ('KNOWN_AS_OF','TRUTH_AS_OF')),
  same_call_excluded boolean not null default true,

  -- What the reviewer saw
  evidence_event_ids uuid[] not null default '{}'::uuid[],
  span_char_start int null,
  span_char_end int null,
  transcript_span_hash text null,

  -- Frozen packet digest (JSON + hash)
  packet_json jsonb not null,
  packet_hash text not null,

  -- Reviewer execution metadata
  reviewer_provider text not null,
  reviewer_model text not null,
  reviewer_prompt_version text not null,
  reviewer_temperature numeric null,
  reviewer_run_id text null,

  -- Reviewer output (structured)
  verdict text not null check (verdict in ('MATCH','MISMATCH','INSUFFICIENT')),
  top_candidates jsonb not null default '[]'::jsonb, -- [{project_id, confidence, anchors:[{type,text,pointer_ref}], rationale}] 
  competing_margin numeric null, -- optional: how close #2 was

  -- Failure taxonomy (small, stable)
  failure_tags text[] not null default '{}'::text[],
  missing_evidence text[] not null default '{}'::text[],

  -- Governance flags
  leakage_violation boolean not null default false,
  pointer_quality_violation boolean not null default false,

  -- Timestamps
  created_at timestamptz not null default now()
);

comment on table public.attribution_audit_ledger is
'Append-only, idempotent ledger of production attribution spotchecks. Rows bind reviewer verdicts to exact span_attributions decisions and frozen evidence packets (known-as-of, same-call excluded). Used for failure bucketing and regression manifests.';

-- Enforce pointer bounds when provided
alter table public.attribution_audit_ledger
  add constraint attribution_audit_span_bounds_ok
  check (
    (span_char_start is null and span_char_end is null)
    or (span_char_start is not null and span_char_end is not null and span_char_start >= 0 and span_char_end > span_char_start)
  );

-- Enforce allowed failure tag vocabulary (small taxonomy). Keep this list stable; add via migration.
alter table public.attribution_audit_ledger
  add constraint attribution_audit_failure_tags_vocab
  check (
    failure_tags <@ array[
      'missing_alias_anchor',
      'wrong_vendor_binding',
      'multi_project_span_ambiguity',
      'known_asof_violation',
      'same_call_leakage',
      'insufficient_provenance_pointer_quality',
      'competing_candidate_too_close',
      'location_anchor_overweight',
      'floater_confusion',
      'timeline_anchor_missing',
      'doc_anchor_missing',
      'matched_terms_spurious'
    ]::text[]
  );

create index if not exists idx_attrib_audit_ledger_created_at
  on public.attribution_audit_ledger (created_at desc);

create index if not exists idx_attrib_audit_ledger_interaction
  on public.attribution_audit_ledger (interaction_id, created_at desc);

create index if not exists idx_attrib_audit_ledger_span_attr
  on public.attribution_audit_ledger (span_attribution_id);

create index if not exists idx_attrib_audit_ledger_verdict
  on public.attribution_audit_ledger (verdict, created_at desc);

create index if not exists idx_attrib_audit_ledger_failure_tags_gin
  on public.attribution_audit_ledger using gin (failure_tags);

create index if not exists idx_attrib_audit_ledger_packet_json_gin
  on public.attribution_audit_ledger using gin (packet_json jsonb_path_ops);

-- 2) Regression manifest: promote representative failures into a durable eval set.

create table if not exists public.attribution_audit_manifest (
  id uuid primary key default gen_random_uuid(),
  name text not null unique, -- e.g. 'attrib_regress_v1'
  description text null,
  created_by text not null default 'system',
  created_at timestamptz not null default now(),
  is_active boolean not null default true
);

comment on table public.attribution_audit_manifest is
'Curated regression manifests for attribution. Each manifest lists ledger rows (or derived packets) that future changes must pass.';

create table if not exists public.attribution_audit_manifest_items (
  id uuid primary key default gen_random_uuid(),
  manifest_id uuid not null references public.attribution_audit_manifest(id) on delete cascade,
  ledger_id uuid not null references public.attribution_audit_ledger(id) on delete cascade,
  added_by text not null default 'system',
  added_at timestamptz not null default now(),
  notes text null,
  unique(manifest_id, ledger_id)
);

create index if not exists idx_attrib_audit_manifest_items_manifest
  on public.attribution_audit_manifest_items (manifest_id, added_at desc);

-- 3) Convenience view: weekly rollup by failure tag + evidence tier + attribution source.

create or replace view public.attribution_audit_failure_rollup_weekly as
with base as (
  select
    date_trunc('week', created_at) as week_utc,
    verdict,
    attribution_source,
    evidence_tier,
    unnest(failure_tags) as failure_tag
  from public.attribution_audit_ledger
)
select
  week_utc,
  failure_tag,
  attribution_source,
  evidence_tier,
  count(*) filter (where verdict='MISMATCH') as mismatch_count,
  count(*) filter (where verdict='INSUFFICIENT') as insufficient_count,
  count(*) as total_flagged
from base
group by 1,2,3,4
order by week_utc desc, total_flagged desc;
;
