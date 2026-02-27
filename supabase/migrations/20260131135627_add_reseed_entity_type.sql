-- Migration: Add 'reseed' entity_type to override_log
-- Purpose: Support re-chunking audit trail
-- Date: 2026-01-31
--
-- POLICY: Uses terminology "reseed" for the operation, "chunking" internally
-- (DB column names unchanged per STRAT directive)

-- Drop existing constraint
ALTER TABLE override_log DROP CONSTRAINT IF EXISTS chk_override_log_entity_type;

-- Add new constraint with 'reseed' type
ALTER TABLE override_log ADD CONSTRAINT chk_override_log_entity_type
  CHECK (entity_type IN (
    'interaction',
    'scheduler_item',
    'project_contacts',
    'correspondent_project_affinity',
    'span_attribution',
    'reseed'
  ));

-- Add comment documenting the entity types
COMMENT ON COLUMN override_log.entity_type IS
  'Type of entity being modified: interaction, scheduler_item, project_contacts, correspondent_project_affinity, span_attribution, reseed';;
