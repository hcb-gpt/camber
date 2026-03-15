# Zap Edge-Secret Rotation Contract (2026-03-04)

## Scope Delivered
- Canonical ingress auth contract for Zap-triggered calls:
  - Required header: `X-Edge-Secret`
  - Secret source: `EDGE_SHARED_SECRET` (+ optional `EDGE_SHARED_SECRET_NEXT` overlap window)
- Deterministic machine error codes:
  - `edge_secret_missing`
  - `invalid_edge_secret`
  - `edge_secret_drift`
- Runtime health surface:
  - `zapier-call-ingest?mode=edge_secret_health`
  - `redline-thread?mode=edge_secret_health`
- Regression tests for:
  - bad secret denied
  - good secret accepted
  - overlap window accepted
  - expired overlap denied

## Deploy Plan
1. Set env vars in Supabase Edge secrets:
   - `EDGE_SHARED_SECRET` (required)
   - `EDGE_SHARED_SECRET_NEXT` (optional during rotation)
   - `EDGE_SHARED_SECRET_NEXT_EXPIRES_AT_UTC` (required when NEXT is set)
2. Deploy functions:
   - `zapier-call-ingest`
   - `redline-thread`
3. Verify health endpoints return `contract_status`:
   - expected `healthy` (or `drift` with explicit reasons)
4. Cutover Zap to new secret:
   - update Zap header `X-Edge-Secret` to NEXT secret
   - keep current+next overlap active until cutover confirmed
5. End overlap:
   - move NEXT into `EDGE_SHARED_SECRET`
   - clear `EDGE_SHARED_SECRET_NEXT*`

## Rollback Plan
1. Restore prior secret:
   - set `EDGE_SHARED_SECRET` back to last known good value
2. Disable overlap if misconfigured:
   - unset `EDGE_SHARED_SECRET_NEXT`
   - unset `EDGE_SHARED_SECRET_NEXT_EXPIRES_AT_UTC`
3. Redeploy:
   - `zapier-call-ingest`
   - `redline-thread`
4. Confirm health endpoint:
   - `contract_status=healthy`
5. Re-run inbound Zap request with known-good `X-Edge-Secret`.
