# Edge Function Auth Contract RFC

**Version:** 1.0.0
**Date:** 2026-02-14
**Author:** DEV-1
**Status:** ACTIVE

## Problem

Pipeline Edge Functions keep deploying with `verify_jwt=false` but inconsistent code-level auth.
This causes runtime 401s when callers use the wrong auth method, and leaves some endpoints
completely unprotected (e.g., morning-digest had zero auth code despite exposing full pipeline data).

## Canonical Auth Contract

### Pattern A: Pipeline Machine-to-Machine (CANONICAL)

**For:** All pipeline-internal Edge Functions called by other functions or cron.

```
Deploy: verify_jwt=false
Code:   X-Edge-Secret header == EDGE_SHARED_SECRET env var
Status: 401 if missing, 403 if invalid
```

**Required headers from caller:**
- `X-Edge-Secret: <EDGE_SHARED_SECRET value>`
- `Content-Type: application/json`

**Implementation:** Use `_shared/auth.ts` module (`requireEdgeSecret()`) for constant-time
comparison. For simpler functions, inline check is acceptable but MUST exist.

**Functions using Pattern A:**
| Function | Auth Code | Source Allowlist | Notes |
|----------|-----------|------------------|-------|
| auto-review-resolver | Inline | Yes | Accepts `X-Edge-Secret` (preferred) or service-role via `Authorization`/`apikey` |
| process-call | Dual (A+B) | N/A | Also accepts JWT |
| segment-call | Inline | No | |
| segment-llm | Inline | No | |
| context-assembly | Inline | No | |
| ai-router | Inline | No | |
| journal-extract | Inline | No | |
| journal-consolidate | Inline | No | |
| chain-detect | Inline | No | |
| striking-detect | Inline | No | |
| generate-summary | Inline | No | |
| loop-closure | Inline | No | |
| morning-digest | Inline | No | **FIXED: was missing auth** |
| admin-reseed | Shared module | Yes: admin-reseed, system | |
| zapier-call-ingest | Inline | No | External webhook |
| shadow-replay | Inline | No | |
| gmail-context-lookup | Inline | No | |
| review-triage | Inline | No | |

### Pattern B: User-Facing (JWT)

**For:** Endpoints called by browser/mobile UI with authenticated Supabase user.

```
Deploy: verify_jwt=true
Code:   Supabase handles JWT validation automatically
Status: 401 if no valid JWT
```

**Functions using Pattern B:**
| Function | Notes |
|----------|-------|
| review-resolve | User reviews claims |
| eval-ai-router | Evaluation tool |
| dlq-enqueue | DLQ management |

### Pattern C: Dual Auth (A + B)

**For:** Endpoints callable by both pipeline (machine) AND users (browser).

```
Deploy: verify_jwt=false
Code:   Accept EITHER X-Edge-Secret OR valid JWT Bearer token
        Check edge secret first (fast path for pipeline)
        Fall back to JWT validation via supabase.auth.getUser()
```

**Functions using Pattern C:**
| Function | Notes |
|----------|-------|
| process-call | Callable by Zapier (edge secret) or UI (JWT) |

### Pattern D: External Webhook

**For:** Endpoints receiving webhooks from external services (Zapier, OpenPhone).

```
Deploy: verify_jwt=false
Code:   X-Edge-Secret (shared with webhook config)
        Additional: validate payload structure
```

**Functions using Pattern D:**
| Function | Notes |
|----------|-------|
| zapier-call-ingest | Zapier webhook |

## Secrets Management

All Edge Functions use these environment variables (set in Supabase Dashboard):

| Secret | Scope | Notes |
|--------|-------|-------|
| `EDGE_SHARED_SECRET` | All Pattern A functions | Single shared secret for pipeline |
| `SUPABASE_URL` | All | Auto-provided by Supabase |
| `SUPABASE_SERVICE_ROLE_KEY` | All | Auto-provided by Supabase |
| `SUPABASE_ANON_KEY` | Pattern C only | For JWT validation |
| `ANTHROPIC_API_KEY` | LLM-calling functions | ai-router, loop-closure, segment-llm, journal-extract |

**Policy:** No operator-local secrets. All secrets managed in Supabase Dashboard → Settings → Edge Functions → Secrets.

## Post-Deploy Smoke Test (MANDATORY)

After deploying ANY Edge Function, run:

```bash
# From camber-calls repo root:
./scripts/edge-smoke-test.sh [function-name]

# Or test all pipeline functions:
./scripts/edge-smoke-test.sh --all
```

The smoke test verifies:
1. **Auth gate:** Request without X-Edge-Secret returns 401
2. **Auth pass:** Request with correct X-Edge-Secret returns 200
3. **Response structure:** Response is valid JSON with expected fields

### Auto-Review Resolver Invocation Notes

For `auto-review-resolver`, use one of these paths:

1. Preferred: `X-Edge-Secret` + `X-Source` allowlist.
2. Compatibility: service-role credentials via either:
   - `Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>`
   - `apikey: <SUPABASE_SERVICE_ROLE_KEY>`

If both `Authorization` and `apikey` are provided, either may satisfy service-role auth.

## Security Gaps Identified and Fixed

1. **morning-digest:** Had ZERO auth code despite `verify_jwt=false` deployment.
   Anyone could GET full pipeline data. **FIXED:** Added X-Edge-Secret check (v1.2.0).

2. **review-triage:** Had ZERO auth code despite `verify_jwt=false` deployment.
   Anyone could read review queue AND auto-dismiss items with dry_run=false.
   **FIXED:** Added X-Edge-Secret check (v1.3.0).

3. **shadow-replay:** `verify_jwt=false` — internal admin tool, auth via X-Edge-Secret. OK.

4. **admin-reseed:** `verify_jwt=false` — uses shared auth module with source allowlist. Best practice.

## Deployment Checklist

Before deploying an Edge Function:

- [ ] `verify_jwt` posture matches auth pattern (A/B/C/D)
- [ ] Auth code exists and matches pattern
- [ ] `EDGE_SHARED_SECRET` is set in Supabase secrets
- [ ] Post-deploy smoke test passes
- [ ] Function documented in this RFC table
