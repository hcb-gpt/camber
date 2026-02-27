-- Convenience view for active (non-superseded) spans
-- Prevents query bugs from forgetting is_superseded filter

CREATE OR REPLACE VIEW v_active_conversation_spans AS
SELECT *
FROM conversation_spans
WHERE is_superseded = false;

COMMENT ON VIEW v_active_conversation_spans IS
  'Active spans only (is_superseded=false). Use for pipeline queries to prevent stale span access.';;
