# Pipeline Model Config Rollout (Deploy + Rollback)

## Scope

This run deploys `ship/latest` edge functions that read centralized model settings from `public.pipeline_model_config` via `_shared/model_config.ts`.

## Deploy

1. Confirm target SHA:
   - `git rev-parse --short HEAD` (expected: `c20cd77` for this rollout)
2. Deploy function set:
   - `ai-router`
   - `segment-llm`
   - `generate-summary`
   - `audit-attribution`
   - `audit-attribution-reviewer`
   - `chain-detect`
   - `striking-detect`
   - `journal-extract`
   - `journal-consolidate`
   - `decision-auditor`
   - `evidence-assembler`
   - `loop-closure`
   - `redline-assistant`
3. Verify deployed versions:
   - `supabase functions list --project-ref rjhdwidddtfetbwqolof --output json`
4. Smoke-check config read:
   - Invoke `audit-attribution` and `audit-attribution-reviewer` with `packet_json`.
   - Confirm response includes `"model_source":"pipeline_model_config"`.

## Fast Rollback

Use this when any deployed function regresses behavior.

### A) Data-plane rollback (preferred, fastest)

No redeploy required. Revert rows in `public.pipeline_model_config` to known-good values:

```sql
UPDATE public.pipeline_model_config
SET model_id = '<known_good_model>',
    max_tokens = <known_good_max_tokens>,
    temperature = <known_good_temperature>,
    updated_at = now(),
    rationale = 'rollback: restore known-good runtime settings'
WHERE function_name IN (
  'ai-router','segment-llm','generate-summary','audit-attribution','audit-attribution-reviewer',
  'chain-detect','striking-detect','journal-extract','journal-consolidate',
  'decision-auditor','evidence-assembler','loop-closure','redline-assistant'
);
```

Then re-invoke the same smoke checks and confirm `"model_source":"pipeline_model_config"` with expected model params in DB.

### B) Code rollback (if behavior changed in source)

1. Checkout known-good commit on `ship/latest`.
2. Re-deploy the same function set.
3. Verify function versions moved forward to rollback deploy revisions.
4. Re-run smoke checks.

## Proof Checklist

- `GIT_PROOF`: deployed SHA from `ship/latest`.
- `DEPLOY_PROOF`: function slug + deployed version from Supabase list output.
- `REAL_DATA_POINTER`: 2+ function invocations showing `model_source=pipeline_model_config`.
- `CONFIG_POINTER`: `pipeline_model_config` rows for those functions (`model_id`, `max_tokens`, `temperature`).
