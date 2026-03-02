# verify_jwt Deploy Guard + Audit (2026-03-02)

## Scope

- Project: `rjhdwidddtfetbwqolof`
- Purpose:
  - Prevent auth drift by enforcing `verify_jwt` contract during deploy.
  - Audit webhook and local function auth contract vs live runtime metadata.

## Guard Added

- Script: `scripts/verify_jwt_drift_guard.sh`
- Contract precedence:
  1. `supabase/functions/<fn>/config.toml` (`verify_jwt` or `[function].verify_jwt`)
  2. `supabase/config.toml` (`[functions.<fn>].verify_jwt`)
  3. default `true`
- Fails non-zero on:
  - `DRIFT`
  - `MISSING_LIVE`
  - `MISSING_FIELD`
  - `NO_CONTRACT` (for explicitly targeted functions not represented in repo)

## CI Wiring

Updated `.github/workflows/deploy-edge-functions.yml`:

1. Resolve expected `verify_jwt` per function from local contract.
2. Deploy with contract-aware mode:
   - `--no-verify-jwt` only when expected is `false`.
   - default deploy behavior when expected is `true`.
3. Post-deploy contract check:
   - `scripts/verify_jwt_drift_guard.sh --functions <matrix.function>`
   - hard fail on mismatch.

## Contract Coverage Added

Added missing per-function auth contracts:

- `supabase/functions/sms-thread-assembler/config.toml` (`verify_jwt=false`)
- `supabase/functions/alias-hygiene/config.toml` (`verify_jwt=false`)
- `supabase/functions/alias-review/config.toml` (`verify_jwt=false`)
- `supabase/functions/alias-scout/config.toml` (`verify_jwt=false`)
- `supabase/functions/review-resolve/config.toml` (`verify_jwt=true`)

## Webhook Audit Result

Webhook audit set:

- `financial-receipt-ingest`
- `process-call`
- `segment-call`
- `sms-beside-batch-ingest`
- `sms-openphone-sync`
- `sms-thread-assembler`
- `sync-google-contacts`
- `zapier-call-ingest`
- `zapier-sms-ingest`

Result:

- In-contract: `process-call`, `segment-call`, `sms-beside-batch-ingest`, `sms-thread-assembler`, `zapier-call-ingest`
- `NO_CONTRACT` (deployed but missing local source-of-truth in this repo):
  - `financial-receipt-ingest`
  - `sms-openphone-sync`
  - `sync-google-contacts`
  - `zapier-sms-ingest`

## Full Local Audit: Remaining Runtime Drifts

After contract additions, remaining `DRIFT` items:

- `assistant-context` (expected `true`, live `false`)
- `morning-manifest-ui` (expected `true`, live `false`)
- `redline-assistant` (expected `true`, live `false`)
- `review-resolve` (expected `true`, live `false`)
- `transcribe-deepgram` (expected `true`, live `false`)

These require targeted remediation decisions and redeploys under change control.
