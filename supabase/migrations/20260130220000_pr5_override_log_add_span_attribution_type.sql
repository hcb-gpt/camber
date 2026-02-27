-- PR-5: Human Resolution Endpoint
-- Single-transaction RPC + schema updates for review resolution
--
-- Changes:
-- 1. Expand override_log entity_type constraint to include 'span_attribution'
-- 2. Add idempotency_key column + unique index to override_log
-- 3. Create resolve_review_item() RPC for atomic resolution
--
-- v3 Fixes (STRAT-1 gates):
-- - AND project_id IS NULL on scheduler_items/journal_claims (no overwrites)
-- - Human-lock conflict guard (can't overwrite human lock with different project)
-- - Assert SSOT rowcount > 0 (fail if no span_attributions row)

begin;
-- ============================================================
-- 1. EXPAND OVERRIDE_LOG ENTITY_TYPE CONSTRAINT
-- ============================================================
alter table public.override_log
  drop constraint if exists chk_override_log_entity_type;
alter table public.override_log
  add constraint chk_override_log_entity_type
  check (entity_type in ('interaction', 'scheduler_item', 'span_attribution'));
comment on constraint chk_override_log_entity_type on public.override_log is
  'Valid entity types for audit: interaction, scheduler_item, span_attribution';
-- ============================================================
-- 2. ADD IDEMPOTENCY_KEY COLUMN + UNIQUE INDEX
-- ============================================================
alter table public.override_log
  add column if not exists idempotency_key text;
create unique index if not exists override_log_idempotency_key_uq
  on public.override_log (idempotency_key)
  where idempotency_key is not null;
comment on column public.override_log.idempotency_key is
  'Unique key for deduplication (e.g., resolve:<review_queue_id>:<project_id>)';
-- ============================================================
-- 3. CREATE RESOLVE_REVIEW_ITEM() RPC
-- ============================================================
-- Atomic resolution: all writes succeed or all fail
-- Returns JSON with results
--
-- GATES (v3):
-- - Human-lock conflict: cannot overwrite human lock with different project
-- - SSOT rowcount assertion: fails if span_attributions update affects 0 rows
-- - No overwrites: scheduler_items/journal_claims only update NULL project_id

create or replace function public.resolve_review_item(
  p_review_queue_id uuid,
  p_chosen_project_id uuid,
  p_notes text default null,
  p_user_id text default null  -- NULL triggers error; must be provided by caller
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review_item record;
  v_span_id uuid;
  v_interaction_id uuid;
  v_call_id text;
  v_from_value text;
  v_existing_lock text;
  v_existing_project uuid;
  v_idempotency_key text;
  v_audit_exists boolean;
  v_ssot_rowcount int;
  v_scheduler_count int := 0;
  v_claims_count int := 0;
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

  -- 2. Idempotency check: already resolved?
  if v_review_item.status in ('resolved', 'dismissed') then
    return jsonb_build_object(
      'ok', true,
      'review_queue_id', p_review_queue_id,
      'span_id', v_span_id,
      'interaction_id', v_interaction_id,
      'chosen_project_id', p_chosen_project_id,
      'was_already_resolved', true,
      'updates', jsonb_build_object(
        'span_attributions', false,
        'review_queue', false,
        'override_log', false,
        'scheduler_items', 0,
        'journal_claims', 0
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
    -- No span_id means legacy call-level item; still fail (span is required for new flow)
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

  -- 9. Update scheduler_items (expanded scope)
  -- GATE: Only update rows where project_id IS NULL (no overwrites)
  if v_interaction_id is not null then
    with updated as (
      update scheduler_items
      set
        project_id = p_chosen_project_id,
        attribution_status = 'resolved',
        needs_review = false
      where interaction_id = v_interaction_id
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
    from interactions
    where id = v_interaction_id;

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
      'journal_claims', v_claims_count
    )
  );
end;
$$;
comment on function public.resolve_review_item is
  'Atomic human resolution of a pending review item. Updates SSOT + audit + scheduler + claims in single transaction. Gates: human-lock conflict, SSOT rowcount assertion, no overwrites on scheduler/claims.';
-- Grant execute to service_role (edge functions use this)
grant execute on function public.resolve_review_item to service_role;
commit;
