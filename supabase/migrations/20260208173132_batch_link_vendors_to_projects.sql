
-- Batch import RPC for vendor-project links
-- Takes a JSON array of {contact_id, project_id, trade} and calls link_vendor_to_project for each
CREATE OR REPLACE FUNCTION public.batch_link_vendors_to_projects(
  p_links jsonb,
  p_source text DEFAULT 'batch_import'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_result jsonb;
  v_results jsonb[] := ARRAY[]::jsonb[];
  v_success_count integer := 0;
  v_error_count integer := 0;
  v_total integer;
BEGIN
  -- Validate input is an array
  IF jsonb_typeof(p_links) != 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'p_links must be a JSON array');
  END IF;

  v_total := jsonb_array_length(p_links);
  
  IF v_total = 0 THEN
    RETURN jsonb_build_object('ok', true, 'total', 0, 'success', 0, 'errors', 0, 'results', '[]'::jsonb);
  END IF;

  -- Process each item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_links)
  LOOP
    -- Validate required fields
    IF v_item->>'contact_id' IS NULL OR v_item->>'project_id' IS NULL THEN
      v_result := jsonb_build_object(
        'ok', false, 
        'error', 'missing_required_field',
        'input', v_item
      );
      v_error_count := v_error_count + 1;
    ELSE
      BEGIN
        v_result := link_vendor_to_project(
          (v_item->>'contact_id')::uuid,
          (v_item->>'project_id')::uuid,
          v_item->>'trade',
          p_source
        );
        
        IF (v_result->>'ok')::boolean THEN
          v_success_count := v_success_count + 1;
        ELSE
          v_error_count := v_error_count + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_result := jsonb_build_object(
          'ok', false,
          'error', SQLERRM,
          'input', v_item
        );
        v_error_count := v_error_count + 1;
      END;
    END IF;
    
    v_results := array_append(v_results, v_result);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', v_error_count = 0,
    'total', v_total,
    'success', v_success_count,
    'errors', v_error_count,
    'source', p_source,
    'results', to_jsonb(v_results)
  );
END;
$$;

COMMENT ON FUNCTION public.batch_link_vendors_to_projects IS 
'Batch import vendor-project links. Input: JSON array of {contact_id, project_id, trade?}. Calls link_vendor_to_project for each row. Integration point C.';
;
