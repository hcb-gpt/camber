-- Materialize scheduler items from interactions.ai_scheduler_json into scheduler_items table.
-- Fires on INSERT or UPDATE of ai_scheduler_json on interactions.
-- Uses ON CONFLICT DO NOTHING with the (interaction_id, item_hash) idempotency index.
--
-- Background: The old router_v3 wrote directly to scheduler_items. The new pipeline
-- has generate-summary writing to interactions.ai_scheduler_json but nothing materialized
-- items into the scheduler_items table. This trigger closes that gap.

CREATE OR REPLACE FUNCTION public.materialize_scheduler_items()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
  item_hash_val text;
BEGIN
  -- Only proceed if ai_scheduler_json is a non-empty array
  IF NEW.ai_scheduler_json IS NULL
     OR jsonb_typeof(NEW.ai_scheduler_json) != 'array'
     OR jsonb_array_length(NEW.ai_scheduler_json) = 0 THEN
    RETURN NEW;
  END IF;

  FOR item IN SELECT jsonb_array_elements(NEW.ai_scheduler_json)
  LOOP
    -- Compute deterministic hash for idempotency (matches old pipeline pattern)
    item_hash_val := left(md5(
      COALESCE(item->>'title', '') || '|' || COALESCE(item->>'action', '')
    ), 8);

    INSERT INTO public.scheduler_items (
      interaction_id,
      item_type,
      title,
      description,
      time_hint,
      assignee,
      status,
      source,
      item_hash,
      project_id,
      attribution_status,
      attribution_confidence,
      needs_review,
      evidence_quote,
      evidence_locator,
      scheduler_schema_version,
      payload,
      meta
    ) VALUES (
      NEW.id,  -- FK to interactions.id (UUID)
      COALESCE(item->>'item_type', 'task'),
      COALESCE(item->>'title', 'Untitled'),
      COALESCE(item->>'action', item->>'description', ''),
      item->>'due_hint',
      item->>'owner',
      'pending',
      COALESCE(item->>'source', 'generate-summary'),
      item_hash_val,
      NEW.project_id,  -- inherit from interaction if available
      CASE
        WHEN NEW.project_id IS NOT NULL THEN 'resolved'
        ELSE 'unknown'
      END,
      CASE
        WHEN NEW.project_id IS NOT NULL THEN 0.80
        ELSE NULL
      END,
      NEW.project_id IS NULL,  -- needs_review if no project
      item->>'evidence_quote',
      item->>'evidence_locator',
      4,  -- schema version 4 for generate-summary source
      item,  -- store full original JSON in payload
      jsonb_build_object(
        'prompt_version', item->>'prompt_version',
        'priority', item->>'priority',
        'span_index_hint', item->>'span_index_hint',
        'generated_at_utc', item->>'generated_at_utc',
        'materialized_by', 'trg_materialize_scheduler_items'
      )
    )
    ON CONFLICT (interaction_id, item_hash) DO NOTHING;
  END LOOP;

  RETURN NEW;
END;
$$;
-- Create the trigger
CREATE TRIGGER trg_materialize_scheduler_items
  AFTER INSERT OR UPDATE OF ai_scheduler_json
  ON public.interactions
  FOR EACH ROW
  WHEN (NEW.ai_scheduler_json IS NOT NULL)
  EXECUTE FUNCTION public.materialize_scheduler_items();
COMMENT ON FUNCTION public.materialize_scheduler_items() IS
  'Materializes scheduler items from interactions.ai_scheduler_json into the scheduler_items table. '
  'Fires after generate-summary writes ai_scheduler_json. Uses item_hash for idempotency.';
