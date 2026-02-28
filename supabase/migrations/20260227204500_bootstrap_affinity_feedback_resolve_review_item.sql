-- Bootstrap loop closure: feed manual resolve_review_item decisions into affinity priors
-- Adds best-effort upsert_affinity_feedback call with contact_id guard.
begin;
CREATE OR REPLACE FUNCTION public.resolve_review_item(
  p_review_queue_id uuid,
  p_chosen_project_id uuid,
  p_notes text default null,
  p_user_id text default null  -- NULL triggers error; must be provided by caller
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_review_item record;
  v_span_id uuid;
  v_interaction_id text;
  v_interaction_uuid uuid;
  v_call_id text;
  v_from_value text;
  v_existing_lock text;
  v_existing_project uuid;
  v_idempotency_key text;
  v_audit_exists boolean;
  v_ssot_rowcount int;
  v_scheduler_count int := 0;
  v_claims_count int := 0;
  v_contact_id uuid;

  v_correction_key text;
  v_corrections_written boolean := false;
  v_corrections_table_exists boolean := false;
  v_corrections_exists boolean := false;
  v_corrections_source_call_id text;
  v_corrections_span_start integer;
  v_corrections_span_end integer;
  v_belief_claim_id uuid;
  v_claim_pointer_id uuid;
  v_correction_type text;
  v_source_stage text := 'review_resolve';
  v_reason text;

  v_has_belief_claim_id boolean;
  v_has_claim_pointer_id boolean;
  v_has_pointer_id boolean;
  v_has_correction_type boolean;
  v_has_error_type boolean;
  v_has_source_stage boolean;
  v_has_original_value boolean;
  v_has_corrected_value boolean;
  v_has_reason boolean;
  v_has_corrected_by boolean;
  v_has_status boolean;
  v_has_notes boolean;
  v_has_idempotency_key boolean;
  v_has_correction_text boolean;

  v_insert_columns text[];
  v_insert_values text[];

  v_insert_sql text;
begin
  -- GATE: user_id must be provided (no hardcoded defaults)
  if p_user_id is null or p_user_id = '' then
    return jsonb_build_object(
      'ok', false,
      'error', 'missing_user_id',
      'detail', 'user_id must be provided from JWT'
    );
  end if;

  -- Build idempotency key
  v_idempotency_key := 'resolve:' || p_review_queue_id::text || ':' || p_chosen_project_id::text;

  -- 1. Load review_queue item (lock row for update)
  select * into v_review_item
  from review_queue
  where id = p_review_queue_id
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'error', 'review_queue_item_not_found'
    );
  end if;

  v_span_id := v_review_item.span_id;
  v_interaction_id := v_review_item.interaction_id;
  if v_interaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    begin
      v_interaction_uuid := v_interaction_id::uuid;
    exception
      when others then
        v_interaction_uuid := null;
    end;
  else
    v_interaction_uuid := null;
  end if;

  -- 2. Idempotency check: already resolved?
  if v_review_item.status in ('resolved', 'dismissed') then
    return jsonb_build_object(
      'ok', true,
      'review_queue_id', p_review_queue_id,
      'span_id', v_span_id,
      'interaction_id', v_interaction_id,
      'chosen_project_id', p_chosen_project_id,
      'was_already_resolved', true,
      'actor', p_user_id,
      'updates', jsonb_build_object(
        'span_attributions', false,
        'review_queue', false,
        'override_log', false,
        'scheduler_items', 0,
        'journal_claims', 0,
        'corrections', false
      )
    );
  end if;

  -- Require pending status
  if v_review_item.status != 'pending' then
    return jsonb_build_object(
      'ok', false,
      'error', 'review_queue_item_not_pending',
      'current_status', v_review_item.status
    );
  end if;

  -- 3. GATE: Human-lock conflict check
  -- Cannot overwrite an existing human lock with a DIFFERENT project
  if v_span_id is not null then
    select attribution_lock, applied_project_id
    into v_existing_lock, v_existing_project
    from span_attributions
    where span_id = v_span_id;

    if v_existing_lock = 'human' and v_existing_project is not null
       and v_existing_project != p_chosen_project_id then
      return jsonb_build_object(
        'ok', false,
        'error', 'human_lock_conflict',
        'detail', 'Cannot overwrite human-locked span with different project',
        'existing_project_id', v_existing_project,
        'requested_project_id', p_chosen_project_id
      );
    end if;
  end if;

  -- 4. Check for existing audit row (idempotency via unique index)
  select exists(
    select 1 from override_log where idempotency_key = v_idempotency_key
  ) into v_audit_exists;

  -- 5. Get current applied_project_id for audit from_value
  v_from_value := v_existing_project::text;

  -- 6. Write audit row (skip if duplicate via idempotency_key)
  if not v_audit_exists then
    insert into override_log (
      entity_type,
      entity_id,
      field_name,
      from_value,
      to_value,
      user_id,
      reason,
      review_queue_id,
      idempotency_key
    ) values (
      'span_attribution',
      v_span_id,
      'applied_project_id',
      v_from_value,
      p_chosen_project_id::text,
      p_user_id,
      coalesce(p_notes, 'Resolved via resolve_review_item RPC'),
      p_review_queue_id,
      v_idempotency_key
    )
    on conflict (idempotency_key) where idempotency_key is not null
    do nothing;
  end if;

  -- 7. Update span_attributions (SSOT) + ASSERT rowcount > 0
  if v_span_id is not null then
    update span_attributions
    set
      applied_project_id = p_chosen_project_id,
      attribution_lock = 'human',
      needs_review = false,
      applied_at_utc = now()
    where span_id = v_span_id;

    get diagnostics v_ssot_rowcount = row_count;

    -- GATE: Fail if SSOT update affected 0 rows (span_attributions row must exist)
    if v_ssot_rowcount = 0 then
      raise exception 'SSOT_UPDATE_FAILED: span_attributions row not found for span_id %', v_span_id;
    end if;
  else
    -- No span_id means legacy call-level item; still fail (span is required for this flow)
    raise exception 'SSOT_UPDATE_FAILED: review_queue item has no span_id';
  end if;

  -- 8. Resolve review_queue
  update review_queue
  set
    status = 'resolved',
    resolved_at = now(),
    resolved_by = p_user_id,
    resolution_action = 'confirmed',
    resolution_notes = p_notes
  where id = p_review_queue_id
    and status = 'pending';

  -- 8b. Bootstrap: update affinity priors from human resolution.
  -- Best effort only; never fail manual resolution if affinity write path errors.
  if v_interaction_id is not null then
    begin
      select i.contact_id
      into v_contact_id
      from interactions i
      where i.interaction_id = v_interaction_id
         or (v_interaction_uuid is not null and i.id = v_interaction_uuid)
      limit 1;

      if v_contact_id is not null then
        begin
          -- Preferred signature includes interaction context for shadow guards.
          perform upsert_affinity_feedback(
            v_contact_id,
            p_chosen_project_id,
            'confirm',
            'redline',
            v_interaction_id::text
          );
        exception
          when undefined_function then
            -- Backward-compatible fallback for 4-arg signature.
            perform upsert_affinity_feedback(
              v_contact_id,
              p_chosen_project_id,
              'confirm',
              'redline'
            );
        end;
      end if;
    exception
      when others then
        raise notice 'resolve_review_item: affinity feedback skipped: %', SQLERRM;
    end;
  end if;

  -- 9. Update scheduler_items (expanded scope)
  -- GATE: Only update rows where project_id IS NULL (no overwrites)
  if v_interaction_uuid is not null then
    with updated as (
      update scheduler_items
      set
        project_id = p_chosen_project_id,
        attribution_status = 'resolved',
        needs_review = false
      where interaction_id = v_interaction_uuid
        and project_id is null  -- GATE: no overwrites
      returning id
    )
    select count(*) into v_scheduler_count from updated;
  end if;

  -- 10. Update journal_claims (expanded scope)
  -- GATE: Only update rows where project_id IS NULL (no overwrites)
  if v_interaction_id is not null then
    -- Get call_id from interactions
    select interaction_id into v_call_id
    from interactions i
    where i.interaction_id = v_interaction_id
       or (v_interaction_uuid is not null and i.id = v_interaction_uuid)
    limit 1;

    if v_call_id is null then
      v_call_id := v_interaction_id;
    end if;

    if v_call_id is not null then
      with updated as (
        update journal_claims
        set project_id = p_chosen_project_id
        where call_id = v_call_id
          and project_id is null  -- GATE: no overwrites
        returning id
      )
      select count(*) into v_claims_count from updated;
    end if;
  end if;

  -- 10b. Best-effort correction write-through for learning loop.
  -- Detect corrections table and available columns to tolerate schema drift.
  select exists(
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = 'corrections'
  ) into v_corrections_table_exists;

  if v_corrections_table_exists then
    v_reason := nullif(trim(coalesce(p_notes, '')), '');
    if v_reason is null then
      if v_review_item.reason_codes is not null then
        v_reason := array_to_string(v_review_item.reason_codes, '; ');
      elsif v_review_item.reasons is not null then
        v_reason := array_to_string(v_review_item.reasons, '; ');
      else
        v_reason := 'review_resolve';
      end if;
    end if;

    -- Best effort mapping from review item to claim and pointer.
    v_correction_type := 'wrong_project';
    if v_review_item.reason_codes is not null then
      if array_position(v_review_item.reason_codes, 'missing_context') is not null then
        v_correction_type := 'missing_context';
      elsif array_position(v_review_item.reason_codes, 'false_positive') is not null then
        v_correction_type := 'false_positive';
      elsif array_position(v_review_item.reason_codes, 'wrong_claim_text') is not null then
        v_correction_type := 'wrong_claim_text';
      elsif array_position(v_review_item.reason_codes, 'wrong_attribution') is not null then
        v_correction_type := 'wrong_attribution';
      elsif array_position(v_review_item.reason_codes, 'wrong_project') is not null then
        v_correction_type := 'wrong_project';
      end if;
    elsif v_review_item.reasons is not null then
      if array_position(v_review_item.reasons, 'missing_context') is not null then
        v_correction_type := 'missing_context';
      elsif array_position(v_review_item.reasons, 'false_positive') is not null then
        v_correction_type := 'false_positive';
      elsif array_position(v_review_item.reasons, 'wrong_claim_text') is not null then
        v_correction_type := 'wrong_claim_text';
      elsif array_position(v_review_item.reasons, 'wrong_attribution') is not null then
        v_correction_type := 'wrong_attribution';
      elsif array_position(v_review_item.reasons, 'wrong_project') is not null then
        v_correction_type := 'wrong_project';
      end if;
    end if;

    if v_interaction_id is not null then
      select interaction_id
      into v_corrections_source_call_id
      from interactions i
      where i.interaction_id = v_interaction_id
         or (v_interaction_uuid is not null and i.id = v_interaction_uuid)
      limit 1;

      if v_corrections_source_call_id is null then
        v_corrections_source_call_id := v_interaction_id;
      end if;

      select char_start, char_end
      into v_corrections_span_start, v_corrections_span_end
      from conversation_spans
      where id = v_span_id;

      if v_corrections_source_call_id is not null then
        if v_corrections_span_start is not null and v_corrections_span_end is not null then
          select cp.claim_id, cp.id
          into v_belief_claim_id, v_claim_pointer_id
          from claim_pointers cp
          where cp.source_type = 'transcript_text'
            and cp.source_id = v_corrections_source_call_id
            and cp.char_start is not null
            and cp.char_end is not null
            and cp.char_start <= v_corrections_span_end
            and cp.char_end >= v_corrections_span_start
          order by cp.created_at desc
          limit 1;
        end if;

        if v_claim_pointer_id is null then
          select cp.claim_id, cp.id
          into v_belief_claim_id, v_claim_pointer_id
          from claim_pointers cp
          where cp.source_type = 'transcript_text'
            and cp.source_id = v_corrections_source_call_id
          order by cp.created_at desc
          limit 1;
        end if;
      end if;
    end if;

    v_correction_key := 'review_resolve:' || p_review_queue_id::text || ':' || p_chosen_project_id::text;

    select
      coalesce(bool_or(column_name = 'belief_claim_id'), false),
      coalesce(bool_or(column_name = 'claim_pointer_id'), false),
      coalesce(bool_or(column_name = 'pointer_id'), false),
      coalesce(bool_or(column_name = 'correction_type'), false),
      coalesce(bool_or(column_name = 'error_type'), false),
      coalesce(bool_or(column_name = 'source_stage'), false),
      coalesce(bool_or(column_name = 'original_value'), false),
      coalesce(bool_or(column_name = 'corrected_value'), false),
      coalesce(bool_or(column_name = 'status'), false),
      coalesce(bool_or(column_name = 'reason'), false),
      coalesce(bool_or(column_name = 'corrected_by'), false),
      coalesce(bool_or(column_name = 'notes'), false),
      coalesce(bool_or(column_name = 'idempotency_key'), false),
      coalesce(bool_or(column_name = 'correction_text'), false)
    into
      v_has_belief_claim_id,
      v_has_claim_pointer_id,
      v_has_pointer_id,
      v_has_correction_type,
      v_has_error_type,
      v_has_source_stage,
      v_has_original_value,
      v_has_corrected_value,
      v_has_status,
      v_has_reason,
      v_has_corrected_by,
      v_has_notes,
      v_has_idempotency_key,
      v_has_correction_text
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'corrections';

    if v_has_idempotency_key then
      execute format(
        'SELECT EXISTS (SELECT 1 FROM public.corrections WHERE idempotency_key = %L)',
        v_correction_key
      ) into v_corrections_exists;
    else
      v_corrections_exists := false;
    end if;

    if v_corrections_exists then
      v_corrections_written := true;
    else
      v_insert_columns := ARRAY[]::text[];
      v_insert_values := ARRAY[]::text[];

      if v_has_belief_claim_id then
        v_insert_columns := array_append(v_insert_columns, 'belief_claim_id');
        v_insert_values := array_append(v_insert_values, coalesce(format('%L', v_belief_claim_id), 'NULL'));
      end if;

      if v_has_claim_pointer_id then
        v_insert_columns := array_append(v_insert_columns, 'claim_pointer_id');
        v_insert_values := array_append(v_insert_values, coalesce(format('%L', v_claim_pointer_id), 'NULL'));
      elsif v_has_pointer_id then
        v_insert_columns := array_append(v_insert_columns, 'pointer_id');
        v_insert_values := array_append(v_insert_values, coalesce(format('%L', v_claim_pointer_id), 'NULL'));
      end if;

      if v_has_correction_type then
        v_insert_columns := array_append(v_insert_columns, 'correction_type');
        v_insert_values := array_append(v_insert_values, format('%L', v_correction_type));
      elsif v_has_error_type then
        v_insert_columns := array_append(v_insert_columns, 'error_type');
        v_insert_values := array_append(v_insert_values, format('%L', v_correction_type));
      end if;

      if v_has_source_stage then
        v_insert_columns := array_append(v_insert_columns, 'source_stage');
        v_insert_values := array_append(v_insert_values, format('%L', v_source_stage));
      end if;

      if v_has_original_value then
        v_insert_columns := array_append(v_insert_columns, 'original_value');
        v_insert_values := array_append(v_insert_values, coalesce(format('%L', v_from_value), 'NULL'));
      end if;

      if v_has_corrected_value then
        v_insert_columns := array_append(v_insert_columns, 'corrected_value');
        v_insert_values := array_append(v_insert_values, format('%L', p_chosen_project_id::text));
      end if;

      if v_has_correction_text and not v_has_corrected_value then
        v_insert_columns := array_append(v_insert_columns, 'correction_text');
        v_insert_values := array_append(
          v_insert_values,
          format(
            '%L',
            'project_id from ' || coalesce(v_from_value, 'NULL') || ' to ' || p_chosen_project_id::text
          )
        );
      end if;

      if v_has_reason then
        v_insert_columns := array_append(v_insert_columns, 'reason');
        v_insert_values := array_append(v_insert_values, format('%L', v_reason));
      end if;

      if v_has_status then
        v_insert_columns := array_append(v_insert_columns, 'status');
        v_insert_values := array_append(v_insert_values, '''applied''');
      end if;

      if v_has_corrected_by then
        v_insert_columns := array_append(v_insert_columns, 'corrected_by');
        v_insert_values := array_append(v_insert_values, format('%L', p_user_id));
      end if;

      if v_has_notes then
        v_insert_columns := array_append(v_insert_columns, 'notes');
        v_insert_values := array_append(v_insert_values, format('%L', coalesce(v_reason, 'review_resolve action')));
      end if;

      if v_has_idempotency_key then
        v_insert_columns := array_append(v_insert_columns, 'idempotency_key');
        v_insert_values := array_append(v_insert_values, format('%L', v_correction_key));
      end if;

      if array_length(v_insert_columns, 1) > 0 then
        v_insert_sql := format(
          'INSERT INTO public.corrections (%s) VALUES (%s)',
          array_to_string(v_insert_columns, ', '),
          array_to_string(v_insert_values, ', ')
        );

        begin
          execute v_insert_sql;
          v_corrections_written := true;
        exception
          when others then
            -- Best-effort write; do not fail manual review transaction.
            v_corrections_written := false;
            raise notice 'resolve_review_item: corrections write skipped: %', SQLERRM;
        end;
      end if;
    end if;
  end if;

  -- 11. Return success with effects receipt
  return jsonb_build_object(
    'ok', true,
    'review_queue_id', p_review_queue_id,
    'span_id', v_span_id,
    'interaction_id', v_interaction_id,
    'chosen_project_id', p_chosen_project_id,
    'was_already_resolved', false,
    'actor', p_user_id,
    'updates', jsonb_build_object(
      'span_attributions', true,
      'review_queue', true,
      'override_log', not v_audit_exists,
      'scheduler_items', v_scheduler_count,
      'journal_claims', v_claims_count,
      'corrections', v_corrections_written
    )
  );
end;
$$;

comment on function public.resolve_review_item is
  'Atomic human resolution of a pending review item. Updates SSOT + audit + scheduler + claims + review_queue and appends correction events to corrections when available.';

grant execute on function public.resolve_review_item to service_role;

commit;
