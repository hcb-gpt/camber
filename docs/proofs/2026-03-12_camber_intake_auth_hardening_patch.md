# CAMBER Intake Auth Hardening Patch

Date: 2026-03-12
Repo: `/Users/chadbarlow/gh/hcb-gpt/camber`
Target receipt: `handoff__vp__dev__camber_intake_auth_hardening_patch__20260312`
Related context:
- `completion__handoff__vp__dev__camber_intake_auth_code_investigation__20260312__20260312T174656Z`
- `completion__handoff__vp__ops__camber_intake_auth_secret_verification__20260312__20260312T174738Z`

## Scope

Code patch only. No deploy, no secrets mutation, no runtime verification against production endpoints.

## What Changed

1. Shared edge-secret contract now resolves canonical env precedence explicitly and surfaces alias drift.
   - `supabase/functions/_shared/edge_secret_contract.ts`
   - Added `resolveEdgeSecretContractEnv()` so callers reuse the same `EDGE_SHARED_SECRET` over `X_EDGE_SECRET` precedence.
   - Added drift reasons for `current_secret_alias_mismatch` and `next_secret_alias_mismatch`.
   - Added `resolveZapierLegacySecretCandidates()` so both ingest paths reuse the same `ZAPIER_INGEST_SECRET` / `ZAPIER_SECRET` candidate set.

2. `zapier-call-ingest` now standardizes its legacy fallback with the shared resolver.
   - `supabase/functions/zapier-call-ingest/index.ts`
   - Non-Beside compatibility auth now accepts either configured legacy Zapier secret env name instead of only the first non-empty one.
   - Version metadata updated to `v1.9.2`.

3. `sms-beside-batch-ingest` now matches the shared canonical contract and fails closed on canonical misconfiguration.
   - `supabase/functions/sms-beside-batch-ingest/index.ts`
   - Compatibility auth now resolves the active edge secret through the shared contract instead of reading `EDGE_SHARED_SECRET` ad hoc.
   - If the canonical edge-secret contract is missing, the function now returns `server_misconfigured` immediately instead of falling through to compatibility logic.
   - Compatibility logging now records which canonical env source won and whether alias drift is present.
   - Version metadata updated to `v1.3.2`.

4. Focused tests were added/extended.
   - Added `supabase/functions/_shared/edge_secret_contract_test.ts`
   - Added `supabase/functions/sms-beside-batch-ingest/auth_gate_test.ts`
   - Extended `supabase/functions/zapier-call-ingest/auth_gate_test.ts`

## Verification

Formatter:

```sh
deno fmt \
  supabase/functions/_shared/edge_secret_contract.ts \
  supabase/functions/_shared/edge_secret_contract_test.ts \
  supabase/functions/zapier-call-ingest/index.ts \
  supabase/functions/zapier-call-ingest/auth_gate_test.ts \
  supabase/functions/sms-beside-batch-ingest/index.ts \
  supabase/functions/sms-beside-batch-ingest/auth_gate_test.ts
```

Test command:

```sh
deno test --allow-read \
  supabase/functions/_shared/edge_secret_contract_test.ts \
  supabase/functions/zapier-call-ingest/auth_gate_test.ts \
  supabase/functions/sms-beside-batch-ingest/auth_gate_test.ts
```

Result:
- `ok | 6 passed | 0 failed`

## Diff Summary

Modified:
- `supabase/functions/_shared/edge_secret_contract.ts`
- `supabase/functions/zapier-call-ingest/index.ts`
- `supabase/functions/sms-beside-batch-ingest/index.ts`
- `supabase/functions/zapier-call-ingest/auth_gate_test.ts`

Added:
- `supabase/functions/_shared/edge_secret_contract_test.ts`
- `supabase/functions/sms-beside-batch-ingest/auth_gate_test.ts`

Unrelated pre-existing worktree changes observed and left untouched:
- `CLAUDE.md`
- `supabase/functions/redline-thread/index.ts`
- existing untracked migrations/proof files already present before this patch

## Short Conclusion

The patch narrows the auth contract around one canonical edge secret resolution path, makes alias drift visible in the shared contract, standardizes legacy Zapier secret handling across both ingest functions, and prevents SMS compatibility auth from masking a missing canonical edge-secret configuration.
