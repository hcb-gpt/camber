-- Suggested aliases: candidates surfaced by alias-scout or manual review,
-- pending operator approval before promotion to project_aliases.
CREATE TABLE suggested_aliases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id),
  alias text NOT NULL,
  alias_type text,
  source text NOT NULL,
  confidence numeric,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  rationale text,
  evidence jsonb,
  span_id uuid,
  suggested_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by text
);
COMMENT ON TABLE suggested_aliases IS
  'Alias candidates surfaced by alias-scout or manual entry, held for operator review before promotion to project_aliases.';
-- Dedup: only one pending suggestion per project + alias
CREATE UNIQUE INDEX idx_suggested_aliases_pending_dedup
ON suggested_aliases (project_id, lower(alias))
WHERE status = 'pending';
-- RLS enabled with no policies = service_role only access
ALTER TABLE suggested_aliases ENABLE ROW LEVEL SECURITY;
