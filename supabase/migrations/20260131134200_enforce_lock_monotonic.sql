-- 20260131134200_enforce_lock_monotonic.sql
-- Trigger: prevents lock downgrades on span_attributions

CREATE OR REPLACE FUNCTION trg_span_attributions_lock_monotonic()
RETURNS TRIGGER AS $$
DECLARE
  lock_order CONSTANT jsonb := '{"human": 3, "ai": 2}'::jsonb;
  old_level int;
  new_level int;
BEGIN
  old_level := COALESCE((lock_order->>OLD.attribution_lock)::int, 0);
  new_level := COALESCE((lock_order->>NEW.attribution_lock)::int, 0);

  IF new_level < old_level THEN
    RAISE EXCEPTION 'Lock downgrade forbidden: % → %',
      COALESCE(OLD.attribution_lock, 'null'),
      COALESCE(NEW.attribution_lock, 'null');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_span_attributions_lock_monotonic ON span_attributions;
CREATE TRIGGER trg_span_attributions_lock_monotonic
BEFORE UPDATE ON span_attributions
FOR EACH ROW
WHEN (OLD.attribution_lock IS DISTINCT FROM NEW.attribution_lock)
EXECUTE FUNCTION trg_span_attributions_lock_monotonic();
