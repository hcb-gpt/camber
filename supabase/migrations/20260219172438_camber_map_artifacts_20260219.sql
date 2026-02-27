begin;

create table if not exists public.camber_map_artifacts (
  artifact_key text primary key,
  content_type text not null,
  body text not null,
  updated_at_utc timestamptz not null default now(),
  meta jsonb null
);

comment on table public.camber_map_artifacts is 'Generated camber-map artifacts (facts.json, map.json, map.md, map.graphml, schema) published from product.';

alter table public.camber_map_artifacts enable row level security;

-- Public read access (this repo is public; artifacts intended to be public)
-- If you later decide artifacts should be private, drop/alter this policy.
drop policy if exists camber_map_artifacts_public_read on public.camber_map_artifacts;
create policy camber_map_artifacts_public_read
  on public.camber_map_artifacts
  for select
  to anon
  using (true);

-- No public writes
-- (writes occur via service role / migrations / internal jobs)

commit;
;
