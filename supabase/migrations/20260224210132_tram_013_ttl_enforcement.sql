
-- Migration 013: TTL enforcement for TRAM messages
-- Problem: 99.6% of messages have no expires_at, making TTL filtering meaningless
-- Solution: Default TTL trigger + backfill + cleanup cron

-- Step 1: Trigger to auto-set expires_at on new messages if not provided
CREATE OR REPLACE FUNCTION tram_set_default_ttl()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Default TTL: 7 days for normal messages, 24h for acks
  IF NEW.expires_at IS NULL THEN
    IF NEW.kind = 'ack' OR NEW.receipt LIKE 'ack_%' THEN
      NEW.expires_at := NEW.created_at + interval '24 hours';
    ELSE
      NEW.expires_at := NEW.created_at + interval '7 days';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Attach trigger (BEFORE INSERT so it sets the value before write)
DROP TRIGGER IF EXISTS trg_tram_default_ttl ON tram_messages;
CREATE TRIGGER trg_tram_default_ttl
  BEFORE INSERT ON tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION tram_set_default_ttl();

-- Step 2: Backfill expires_at for existing messages
-- Acks get 24h TTL, everything else gets 7 days
UPDATE tram_messages 
SET expires_at = CASE 
  WHEN kind = 'ack' OR receipt LIKE 'ack_%' THEN created_at + interval '24 hours'
  ELSE created_at + interval '7 days'
END
WHERE expires_at IS NULL;

-- Step 3: Cleanup function for resolved expired messages
CREATE OR REPLACE FUNCTION tram_cleanup_expired()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cleaned integer;
BEGIN
  -- Mark expired unresolved messages as DEFERRED
  UPDATE tram_messages
  SET resolution = 'DEFERRED'
  WHERE expires_at < now()
    AND resolution IS NULL
    AND acked = false;
  
  GET DIAGNOSTICS cleaned = ROW_COUNT;
  RETURN cleaned;
END;
$$;

-- Step 4: Schedule hourly cleanup
SELECT cron.schedule(
  'tram-ttl-cleanup',
  '0 * * * *',  -- Every hour on the hour
  $$SELECT tram_cleanup_expired()$$
);

COMMENT ON FUNCTION tram_set_default_ttl() IS 'Auto-sets expires_at on new TRAM messages: 24h for acks, 7 days for everything else';
COMMENT ON FUNCTION tram_cleanup_expired() IS 'Hourly cron: marks expired unacked messages as DEFERRED resolution';
;
