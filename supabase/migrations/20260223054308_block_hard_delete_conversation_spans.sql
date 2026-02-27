-- Block hard deletes on conversation_spans to enforce supersede/generation semantics.
-- Allows deletes only for explicit fixture/test data and in privileged postgres contexts.

create or replace function public.block_hard_delete_conversation_spans()
returns trigger
language plpgsql
security definer
as $$
begin
  -- Allow privileged maintenance (postgres) to proceed.
  if current_user = 'postgres' or session_user = 'postgres' then
    return old;
  end if;

  -- Allow fixture/test interactions to be hard-deleted.
  if old.interaction_id ilike 'cll_dev%' or old.interaction_id ilike 'cll_shadow%' or old.interaction_id ilike 'cll_racechk%' or old.interaction_id ilike '%_test_%' then
    return old;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'Hard delete on public.conversation_spans is disabled. Use supersede/generation semantics (set is_superseded=true / increment generation) instead.',
    detail = format('blocked span_id=%s interaction_id=%s span_index=%s', old.id, old.interaction_id, old.span_index),
    hint = 'Update writer to supersede spans rather than deleting rows.';
end;
$$;

drop trigger if exists trg_block_hard_delete_conversation_spans on public.conversation_spans;

create trigger trg_block_hard_delete_conversation_spans
before delete on public.conversation_spans
for each row
execute function public.block_hard_delete_conversation_spans();

comment on function public.block_hard_delete_conversation_spans is
'Prevents hard deletes on conversation_spans (except fixture/test data or postgres maintenance). Enforces supersede/generation semantics.';
;
