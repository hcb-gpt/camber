# Auth Exposure Remediation Matrix (2026-03-02)

## Objective

Reduce auth risk quickly by giving owners a deterministic remediation order and verification commands.

## Confirmed Runtime/Auth Drift (High Priority)

| Function | Intended contract | Current live signal | Risk | Recommended action |
|---|---|---|---|---|
| `redline-assistant` | `verify_jwt=true` (project config) | unauthenticated POST returned `200` stream | Public model invocation surface | Flip live `verify_jwt=true`; verify client JWT flow; no-auth probe must fail at gateway |
| `assistant-context` | requires explicit auth decision (currently no local contract) | unauthenticated GET returned `200` with project/pipeline data | Data exposure | Decide contract (`verify_jwt=true` likely), add in-repo config, redeploy, verify no-auth blocked |
| `review-resolve` | `verify_jwt=true` + in-function user check | no-auth POST returned in-function `401` | Gateway drift lowers defense-in-depth | Flip live `verify_jwt=true`; keep in-function auth check |
| `morning-manifest-ui` | `verify_jwt=true` + in-function bearer check | no-auth GET returned in-function `401` | Gateway drift lowers defense-in-depth | Flip live `verify_jwt=true`; keep in-function auth check |
| `transcribe-deepgram` | requires explicit auth decision (currently no local contract) | no-auth POST reached app logic (`400 missing_recording_url`) | Reachable unauthenticated endpoint | Decide contract (`verify_jwt=true` likely), add config, redeploy |

## Known Internal Functions Expected `verify_jwt=false`

These should remain gateway-open but must enforce internal auth gates (`X-Edge-Secret` and/or service role checks):

- `sms-beside-batch-ingest`
- `process-call`
- `segment-call`
- `zapier-call-ingest`
- `sms-thread-assembler`
- `alias-hygiene`
- `alias-review`
- `alias-scout`

## No-Contract Runtime Functions (Triage Needed)

Deployed in runtime but no explicit local contract file in this repo:

- `financial-receipt-ingest`
- `sms-openphone-sync`
- `sync-google-contacts`
- `zapier-sms-ingest`

Action: import source or explicitly mark out-of-scope/deprecated to avoid blind auth drift.

## Recommended Remediation Sequence

1. **P0**: `redline-assistant`, `assistant-context` (publicly invocable now).
2. **P1**: `review-resolve`, `morning-manifest-ui` (defense-in-depth gap).
3. **P1/P2**: `transcribe-deepgram` contract decision + enforcement.
4. **P2**: close `NO_CONTRACT` inventory.

## Verification Commands

Read live metadata:

```bash
supabase functions list --project-ref rjhdwidddtfetbwqolof --output json \
  | jq -r '.[] | {slug,verify_jwt,version,updated_at}'
```

Deploy with contract:

```bash
# verify_jwt=false contract
supabase functions deploy <fn> --project-ref rjhdwidddtfetbwqolof --no-verify-jwt

# verify_jwt=true contract (default)
supabase functions deploy <fn> --project-ref rjhdwidddtfetbwqolof
```

Guard check:

```bash
scripts/verify_jwt_drift_guard.sh \
  --project-ref rjhdwidddtfetbwqolof \
  --functions "<fn>"
```

No-auth probe (must fail for `verify_jwt=true` endpoints):

```bash
curl -sS -o /tmp/body.json -w "%{http_code}\n" \
  "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/<fn>"
cat /tmp/body.json
```
