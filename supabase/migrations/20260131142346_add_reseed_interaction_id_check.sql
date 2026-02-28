-- Require interaction_id for reseed rows
ALTER TABLE override_log
  ADD CONSTRAINT override_log_reseed_interaction_id_check
  CHECK (
    entity_type != 'reseed' 
    OR (interaction_id IS NOT NULL AND interaction_id != '')
  );

COMMENT ON CONSTRAINT override_log_reseed_interaction_id_check ON override_log IS
  'Reseed rows must have non-empty interaction_id (canonical link per STRAT TURN:63)';;
