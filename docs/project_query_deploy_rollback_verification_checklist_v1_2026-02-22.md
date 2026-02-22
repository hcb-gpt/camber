# Project-Query Deploy Rollback/Verification Checklist v1 (2026-02-22)

## 1) Scope and lane guardrails
- Session: `dev-4` (standby/deconflict lane)
- Purpose: fast verification and rollback playbook for `project-query` deploy outcomes.
- Protected lane rule: no edits to `supabase/functions/morning-digest/index.ts`.
- This checklist is read-only process guidance; no schema or runtime code changes required.

## 2) Required context and env
- Repo: `camber-calls`
- Project ref: `rjhdwidddtfetbwqolof`
- Required env:
  - `SUPABASE_URL`
  - `EDGE_SHARED_SECRET`
- Required headers for invoke:
  - `X-Edge-Secret: $EDGE_SHARED_SECRET`
  - `X-Source: project-query-test` (allowlisted in function)

## 3) Success-path verification (post-deploy)
1. Confirm function deploy command completed:
```bash
supabase functions deploy project-query --project-ref rjhdwidddtfetbwqolof --no-verify-jwt
```
2. Smoke invoke with auth + source:
```bash
curl -sS "${SUPABASE_URL}/functions/v1/project-query?limit=1" \
  -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
  -H "X-Source: project-query-test" | jq
```
3. Expected response checks:
   - `ok=true`
   - `function_version` present
   - `data.project_feed` is an array
   - No auth error (`missing_edge_secret`, `invalid_edge_secret`, `missing_source`, `source_not_allowed`)
4. Optional project-scoped check:
```bash
curl -sS "${SUPABASE_URL}/functions/v1/project-query?project_id=<uuid>&limit=3" \
  -H "X-Edge-Secret: ${EDGE_SHARED_SECRET}" \
  -H "X-Source: project-query-test" | jq
```

## 4) Failure signatures and immediate triage
- `401 missing_edge_secret`: missing `X-Edge-Secret` header.
- `403 invalid_edge_secret`: secret mismatch between caller and function env.
- `401 missing_source`: missing `X-Source` (or `source`) header.
- `403 source_not_allowed`: source header not in allowlist.
- `500 project_feed_query_failed`: downstream DB/view query failure; inspect DB/view health and function logs.
- `400 invalid_project_id`: project id is not UUID.

Quick triage checks:
```bash
rg -n "ALLOWED_SOURCES|FUNCTION_VERSION|IMPLEMENTATION_CITATION" supabase/functions/project-query/index.ts
rg -n "requireEdgeSecret|missing_source|source_not_allowed" supabase/functions/_shared/auth.ts
```

## 5) Rollback procedure (function-only)
1. Identify known-good commit SHA for `supabase/functions/project-query/index.ts`.
2. Restore function file from that SHA:
```bash
git checkout <known_good_sha> -- supabase/functions/project-query/index.ts
```
3. Redeploy:
```bash
supabase functions deploy project-query --project-ref rjhdwidddtfetbwqolof --no-verify-jwt
```
4. Re-run success-path verification (Section 3).
5. If rollback verified, post receipt with:
   - rollback commit SHA
   - deploy confirmation
   - smoke-response proof snippet (`ok`, `function_version`, `ms`)

## 6) Artifact pointers
- Runtime function: `supabase/functions/project-query/index.ts`
- Shared auth gate: `supabase/functions/_shared/auth.ts`
- Supabase function config: `supabase/config.toml`
- Standby task claim reference: `claim__dev4_standby_project_query_rollback_verification_checklist_v1__20260222`

## 7) Completion receipt template
Use this when closing the standby checklist item:
```text
RECEIPT: completion__dev4_standby_project_query_rollback_verification_checklist_v1__20260222
RESOLUTION: FIXED
DELIVERABLE: docs/project_query_deploy_rollback_verification_checklist_v1_2026-02-22.md
CONTEXT_AVAILABILITY: db=UNKNOWN; git=YES; local_files=YES; web=NO; provider_ui=NO; transcript=YES
CONTEXT_GAPS: live deploy/runtime logs not executed in this checklist-only pass
```
