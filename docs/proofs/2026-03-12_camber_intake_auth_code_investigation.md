# CAMBER Intake Auth Code Investigation

Date: 2026-03-12
Scope: code-only inspection, no edits
Repo: `/Users/chadbarlow/gh/hcb-gpt/camber`
Target receipt: `handoff__vp__dev__camber_intake_auth_code_investigation__20260312`

## Executive Conclusion

`zapier-call-ingest` `v1.9.1` did **not** introduce a new Beside call-auth behavior relative to the `v1.8.2` hotfix snapshot. Both versions require a valid `X-Edge-Secret` for Beside-shaped call payloads and only allow legacy `X-Secret` for non-Beside payloads.

The likely regression is instead between mainline `v1.9.0` and `v1.9.1`: `v1.9.0` accepted either canonical `X-Edge-Secret` or legacy `X-Secret` for Beside calls, while `v1.9.1` tightened Beside calls to canonical `X-Edge-Secret` only.

`sms-beside-batch-ingest` is on a separate version line. Its auth moved in the opposite direction on `v1.3.1`: it added a compatibility window and is now more permissive than before, while still enforcing an `X-Source` allowlist.

## Version / Branch Map

- `ad84022` `2026-03-04T07:59:05-05:00` `fix(zapier-call-ingest): require X-Edge-Secret for Beside payload auth`
- `3f2f602` `2026-03-01T15:39:12-05:00` `fix: normalize Go-style timestamps in zapier-call-ingest Beside passthrough`
- `9d7344a` `2026-03-04T07:57:26-05:00` `fix(auth): require X-Edge-Secret for Beside zapier-call-ingest path (#402)`
- `310126d` `2026-02-27T15:52:37-05:00` `feat: implement zapier-shadow events write for Beside parity metrics`
- `58c20a6` `2026-03-03T04:09:57-05:00` `Add auth compatibility window for sms Zapier ingest`

`ad84022` is not an ancestor of `9d7344a`; the `v1.8.2` hotfix and `v1.9.1` mainline change are parallel implementations of the same Beside call hardening, not a simple linear version bump.

## 1. Call Ingest: `zapier-call-ingest`

Relevant file: `supabase/functions/zapier-call-ingest/index.ts`

### `v1.8.2` hotfix (`ad84022`)

Auth material loading:
- `X-Edge-Secret` is read into `incomingXEdgeSecret`.
- `X-Secret` is read into `incomingXSecret`.
- `EDGE_SHARED_SECRET` is the canonical expected secret.
- `ZAPIER_INGEST_SECRET` or `ZAPIER_SECRET` is the legacy expected secret.
- Evidence: `ad84022:index.ts` lines 181-200.

Beside payload detection and gate:
- Beside payloads are detected by `isBesidePayload(payload)`.
- Once on the Beside path, the function rejects unless `canonicalValid` is true.
- Legacy `X-Secret` is not enough for Beside calls.
- Evidence: `ad84022:index.ts` lines 232-253.

Non-Beside gate:
- Non-Beside payloads still accept either canonical `X-Edge-Secret` or legacy `X-Secret`.
- Evidence: `ad84022:index.ts` lines 202-230 and 334-363.

### `v1.9.1` mainline (`9d7344a`)

Auth material loading:
- Same split: canonical `X-Edge-Secret` vs `EDGE_SHARED_SECRET`, legacy `X-Secret` vs `ZAPIER_INGEST_SECRET|ZAPIER_SECRET`.
- Evidence: `9d7344a:index.ts` lines 166-185.

Beside payload detection and gate:
- Same effective rule: Beside payloads are rejected unless `canonicalValid` is true.
- Evidence: `9d7344a:index.ts` lines 187-215.

Non-Beside gate:
- Same effective rule: non-Beside payloads still accept canonical or legacy auth.
- Evidence: `9d7344a:index.ts` lines 302-331.

### Exact Delta: `v1.8.2` vs `v1.9.1`

No effective auth-policy change for Beside call payloads:
- `v1.8.2`: Beside calls require canonical `X-Edge-Secret`.
- `v1.9.1`: Beside calls require canonical `X-Edge-Secret`.

Minor differences only:
- `v1.8.2` returns `403` with `invalid_token_for_beside` and a message.
- `v1.9.1` returns `401` with `invalid_token`.
- `v1.9.1` adds KPI/logging fields for missing legacy/canonical headers.

### Why the regression still looks real

The real mainline hardening happened between `v1.9.0` and `v1.9.1`, not between `v1.8.2` and `v1.9.1`.

In `v1.9.0` (`3f2f602`):
- Beside calls were allowed if either `canonicalValid` or `legacyValid` was true.
- Rejection only happened when both were false.
- Evidence: `3f2f602:index.ts` lines 185-207.

Therefore:
- If production moved from mainline `v1.9.0` to mainline `v1.9.1`, a caller still sending `X-Secret` or an old legacy secret would start failing on Beside call ingest.
- If production was truly on the `v1.8.2` hotfix behavior before `v1.9.1`, then `v1.9.1` did not introduce a new call-auth regression.

## 2. SMS Ingest: `sms-beside-batch-ingest`

Relevant file: `supabase/functions/sms-beside-batch-ingest/index.ts`

### `v1.3.0` (`310126d`)

Base auth rule:
- Calls `requireEdgeSecret(req, ALLOWED_SOURCES)` and rejects immediately on failure.
- Evidence: `310126d:index.ts` lines 120-124.

What `requireEdgeSecret` enforces:
- Canonical `X-Edge-Secret` must match the edge-secret contract.
- `X-Source` or `source` must be in the allowlist.
- Evidence: `_shared/auth.ts` lines 29-55 and `_shared/edge_secret_contract.ts` lines 126-201.

### `v1.3.1` (`58c20a6`)

Base auth rule still runs first:
- Calls `requireEdgeSecret(req, ALLOWED_SOURCES)`.
- Evidence: `58c20a6:index.ts` lines 134-135.

Compatibility window if that first check fails:
- Requires `sourceAllowed`.
- Accepts `X-Secret == EDGE_SHARED_SECRET`.
- Accepts either header matching any of:
  `ZAPIER_INGEST_SECRET`, `ZAPIER_SECRET`, `EDGE_SHARED_SECRET_PREVIOUS`.
- Evidence: `58c20a6:index.ts` lines 136-173.

### Exact SMS auth behavior

SMS is stricter than call ingest in one way and looser in another:
- Stricter: it enforces `X-Source` allowlisting.
- Looser: it has an explicit compatibility window for header/secret drift.

So SMS and call ingest are no longer symmetric:
- Call Beside path: canonical `X-Edge-Secret` only.
- SMS Beside path: canonical edge-secret path first, then compatibility fallback, still source-gated.

## 3. Likely Regression Path

Most likely code-level explanation:
- Beside call sender kept using `X-Secret` or a stale legacy secret.
- Mainline `zapier-call-ingest v1.9.1` rejects that on the Beside call path before `calls_raw` upsert.
- `sms-beside-batch-ingest v1.3.1` still accepts that sender through its compatibility window, so SMS appears healthy while call ingest fails.

That matches the observed asymmetry in code:
- Call path hardened to canonical-only on Beside requests.
- SMS path explicitly retained a compatibility window for header/secret drift.

## 4. Short Answer

- Did `v1.9.1` change call auth vs `v1.8.2`? No, not relative to the `v1.8.2` hotfix snapshot. Both are canonical-only for Beside calls.
- Did `v1.9.1` change call auth vs `v1.9.0` mainline? Yes. That is the likely regression edge.
- Did SMS change in the same direction? No. SMS became more permissive on `v1.3.1`, with a compatibility fallback plus source allowlist.
