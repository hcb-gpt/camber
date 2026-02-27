-- Phase 1: Auto-fill correlation_id and thread from parent when in_reply_to is set
-- Prevents orphaned replies that break thread/correlation queries
-- Thread: tram-vnext

CREATE OR REPLACE FUNCTION tram_inherit_reply_context()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  parent RECORD;
BEGIN
  -- Only act when in_reply_to is set
  IF NEW.in_reply_to IS NULL THEN
    RETURN NEW;
  END IF;

  -- Only fill missing fields (don't overwrite explicit values)
  IF NEW.correlation_id IS NOT NULL AND NEW.thread IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Look up parent message
  SELECT correlation_id, thread
  INTO parent
  FROM tram_messages
  WHERE receipt = NEW.in_reply_to;

  -- If parent found, inherit missing fields
  IF FOUND THEN
    IF NEW.correlation_id IS NULL AND parent.correlation_id IS NOT NULL THEN
      NEW.correlation_id := parent.correlation_id;
    END IF;
    IF NEW.thread IS NULL AND parent.thread IS NOT NULL THEN
      NEW.thread := parent.thread;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Fire BEFORE INSERT, after existing triggers that validate but before final write
CREATE TRIGGER trg_tram_inherit_reply_context
  BEFORE INSERT ON tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_inherit_reply_context();
;
