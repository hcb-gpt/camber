-- Add active column to project_aliases for soft-delete support
ALTER TABLE project_aliases ADD COLUMN active BOOLEAN NOT NULL DEFAULT true;
-- Partial index for fast lookups on active aliases
CREATE INDEX idx_project_aliases_active_lookup
ON project_aliases (project_id, lower(alias))
WHERE active = true;
