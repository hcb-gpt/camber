# iOS Internal-Mode Safe Write Auth Handshake v0

Date: 2026-03-03  
Owner lane: DEV (iOS follow-on auth hardening)

## Decision

Adopt a server-minted short-lived write token handshake for privileged iOS write actions, and phase out static `X-Edge-Secret` usage in client builds.

The token is:
- short TTL (default 120 seconds),
- scope-bound (`bootstrap-review:resolve|dismiss|undo`),
- single-use (nonce/jti replay guard),
- revocable server-side.

`X-Edge-Secret` remains accepted only as a temporary backward-compat path for internal ops while migration is active.

## Problem

Current internal mode can rely on a Keychain-stored `X-Edge-Secret`. This is operationally useful but not a good long-term mobile security posture because:
- static shared secret in client context has high blast radius,
- rotation is painful,
- compromise of one app context can expose privileged write capability.

## v0 Handshake Overview

1. iOS requests a write token from a dedicated mint endpoint.
2. Server authenticates request as allowed internal-mode caller.
3. Server returns one short-lived signed token with strict scope.
4. iOS performs write action using the minted token.
5. Write endpoint validates token claims + replay guard + revocation state.

## Minimal API Surface

### 1) Mint endpoint

`POST /functions/v1/internal-auth?action=issue_write_token`

Request headers:
- `Authorization: Bearer <supabase_anon_jwt>`
- `X-Internal-Mode: true`
- `X-Device-ID: <stable-device-id-hash>`

Request body:
- `scope` (required): enum, initially `bootstrap-review:resolve|dismiss|undo`
- `interaction_id` (optional)
- `review_queue_id` (optional)

Response:
- `200` with `{ token, expires_at_utc, scope, jti }`
- `403 invalid_auth` if caller is not allowed to mint

### 2) Write endpoints (bootstrap-review)

`POST /functions/v1/bootstrap-review?action=resolve|dismiss|undo`

Accepted auth during migration:
- `Authorization: Bearer <internal_write_token>` (new)
- `X-Edge-Secret: <secret>` (legacy fallback, sunset planned)

Canonical auth failure response:
- `403`
- `error_code: invalid_auth`
- `error: Write actions require privileged write token or X-Edge-Secret`

## Threat Model Notes

Replay:
- Require unique `jti` + `nonce`, stored server-side with TTL.
- Reject reused token (`token_replayed`).

Device compromise:
- Keep tokens very short-lived and scope-limited.
- Bind token claims to device hash and audience.
- Keep privileged write capability disabled by default; internal mode must be explicit.

Token scope + TTL:
- Scope must map to exact allowed action set.
- Default TTL 120s, max 300s.

Revocation:
- Server-side deny-list for `jti` and device-level kill switch.
- Optional emergency global mint disable flag.

Logging redaction:
- Never log raw token or secret.
- Log only request_id, token fingerprint (hash prefix), scope, decision.

## Backward-Compatibility Plan

Phase 0 (now):
- Keep `X-Edge-Secret` path for internal ops.
- Preserve deterministic `403 invalid_auth` contract for unauthorized writes.

Phase 1 (prototype):
- Implement mint endpoint + token validation on bootstrap-review.
- iOS internal mode prefers minted token, fallback to secret only when explicitly enabled.

Phase 2 (migration):
- Disable fallback in iOS builds.
- Restrict fallback to server-side/internal tooling only.

Phase 3 (sunset):
- Remove `X-Edge-Secret` acceptance from iOS-facing write path.

## Recommendation (1 paragraph)

Ship a prototype first, not full production rollout. The next milestone should implement mint + validate for bootstrap-review only, with strict short TTL and replay guard, and collect operational telemetry (mint success rate, replay rejects, write latency, fallback usage). If prototype metrics are stable and fallback usage is near zero for one full operating week, proceed to migration phase and remove client secret dependency from iOS internal mode.
