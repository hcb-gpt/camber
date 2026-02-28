-- Hotfix: make ai-router auto-assign threshold DB-configurable and set 0.60.
-- Rollback:
--   update public.inference_config
--   set config_value = '0.75'::jsonb,
--       description = 'AI router confidence >= this for auto-assign gate (rollback to pre-hotfix)',
--       updated_by = 'data-1-rollback-20260228',
--       updated_at = now()
--   where config_key = 'ai_router_auto_assign_threshold';

begin;

insert into public.inference_config (
  config_key,
  config_value,
  description,
  updated_by
)
values (
  'ai_router_auto_assign_threshold',
  '0.60'::jsonb,
  'AI router confidence >= this for auto-assign gate. Tuned from 0.75 to 0.60 for deterministic recall hotfix.',
  'data-1-hotfix-20260228'
)
on conflict (config_key) do update
set
  config_value = excluded.config_value,
  description = excluded.description,
  updated_by = excluded.updated_by,
  updated_at = now();

commit;
