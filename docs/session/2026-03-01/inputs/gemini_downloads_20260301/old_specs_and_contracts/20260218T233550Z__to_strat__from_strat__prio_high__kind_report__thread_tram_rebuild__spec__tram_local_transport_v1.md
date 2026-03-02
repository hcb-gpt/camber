TO:STRAT FROM:STRAT TURN:3594 TS_UTC:2026-02-18T23:35:50Z RECEIPT:spec__tram_local_transport_v1 CORRELATION_ID:orb_20260218_f7edd7fa
---
TASK: 
CONTEXT_PTRS: 
REQUESTED_ACTIONS: 
EXPECTED_RECEIPT: 
PRIORITY: HIGH
CORRELATION_ID: orb_20260218_f7edd7fa
IN_REPLY_TO: delegation__spec_tram_local_instant_persistent__20260218
---

FOR_SESSION: strat-1

SPEC PACKET: spec__tram_local_transport_v1 (local instant + persistent TRAM)

1) GOALS / NON-GOALS / DEFINITIONS

Goals
- Instant delivery for *local* agent runtimes (Codex Desktop ↔ Claude Code CLI) with P95 <2s from TRAM create→client notification.
- Persistent/durable: if a client is offline, it receives backlog on reconnect without manual “check TRAM”.
- Passive/low-chatter: no periodic polling, no periodic “heartbeat” TRAM messages. Idle behavior should be just a single websocket keepalive.
- Correct routing semantics preserved: `to=ROLE` broadcast, `FOR_SESSION:` pinning, `CC_FOR_SESSION:` optional.
- Minimal incremental surface area: build on existing DB-canonical TRAM + existing GitHub/Drive replication (still the audit trail).

Non-goals
- Replacing TRAM semantics or storage (DB/GitHub/Drive remain canonical).
- Browser agents: they remain MCP-only (no localhost access).
- Exactly-once delivery (we’ll do at-least-once + dedupe).
- New mission/policy; this is transport only.

Definitions
- Online: client has an active connection to the local relay (or directly to Realtime) and has consumed events within a short window (e.g., last 60s).
- Recently active: derived from *existing events* (message read/ack/create) in last N minutes; no new heartbeat writes.
- Local: processes on same machine (loopback / unix socket).

2) ARCH OPTIONS + RECOMMENDATION

Option A — Direct Supabase Realtime per client
- Each runtime (Codex, Claude) holds its own Supabase auth + subscribes to TRAM rows.
Pros: no daemon.
Cons: key sprawl; duplicated sockets; harder to spool/backfill consistently; more per-client complexity.

Option B — Local relay daemon (RECOMMENDED)
- One small background process maintains a single Supabase Realtime subscription and exposes a localhost transport to any local agent clients.
Pros: single socket to Supabase; isolates secrets; adds durable local spool; zero LLM involvement at idle; easy multi-client fanout.
Cons: extra moving part.

Option C — Git/Drive file watchers
- Pulling repo or Drive periodically.
Pros: simplest conceptually.
Cons: not instant; requires polling; brittle.

Recommendation: Option B. Implement a `tram-relay` (local) + a thin `tram-client` adapter for Codex and Claude Code.

3) DATA MODEL + DELIVERY SEMANTICS

Canonical source stays: TRAM DB rows (plus GitHub/Drive mirror).

Realtime event source
- Subscribe to INSERTs on TRAM message table (and optionally UPDATEs for ack/read).
- Filter on `to` + `expires_at` server-side if possible; session routing can be filtered client-side initially.

Routing / session pinning
- Initial (no schema change): relay parses message body for:
  - `FOR_SESSION: <id>`
  - `CC_FOR_SESSION: <id>`
  - If `FOR_SESSION` present and doesn’t match, do not surface as “needs action” and do not allow ACK.
- Phase 1 schema improvement (recommended): add DB columns `for_session`, `cc_for_session` populated by server-side parse (trigger). This allows server-side realtime filters and cheaper clients.

Delivery semantics
- At-least-once delivery.
- Dedupe key: `receipt` (preferred) else `(correlation_id, created_at, subject)`.
- Ordering: best-effort by `created_at` then `turn` when present.

ACK / READ semantics
- ACK is still written to DB via existing TRAM ack path.
- Relay should prevent “wrong session ACK” by enforcing FOR_SESSION locally.

4) SECURITY MODEL

Supabase auth
- Preferred: per-role JWT minted for the relay (STRAT/DEV/DATA) with RLS read limited to:
  - rows where `to=<role>` OR (future) `to='ALL'`.
- Avoid embedding service-role keys in multiple clients. If service-role must be used, confine it to relay-only and store via OS keychain.

Local security
- Relay listens on unix domain socket (preferred) or 127.0.0.1 TCP.
- File perms / user perms provide primary trust boundary.
- Client auth: short shared token (env var) to prevent other local users from subscribing.

Browser constraint
- Browser agents cannot use localhost; remain MCP-only. No special work needed.

5) FAILURE MODES + RECOVERY

Realtime disconnect
- Relay reconnects with exponential backoff.
- On reconnect, run backfill query from `last_seen_created_at - safety_window(2m)`.

Client offline
- Relay keeps local sqlite spool (or append-only log) for last N days / N messages.
- Client reconnect triggers “catch-up” from spool first, then from DB if needed.

Partial failures
- If realtime event arrives without full content, relay fetches message by id/receipt once; retries on failure.

Dupes
- Dedupe cache in relay (LRU keyed by receipt).

6) MINIMAL IMPLEMENTATION PLAN + ACCEPTANCE

Phase 0 (1–2 days DEV effort; no DB schema changes)
- Build `tram-relay`:
  - One Supabase Realtime subscription.
  - Local socket API: `subscribe(role, session_id)` → stream of events.
  - Local spool + cursor.
  - Parse FOR_SESSION/CC_FOR_SESSION from message text.
- Build adapters:
  - Codex Desktop: small shim that wakes the agent only on new events.
  - Claude Code CLI: same.

Phase 1 (optional but high leverage)
- Add DB columns: `for_session`, `cc_for_session` (+ index).
- Add trigger/parser on insert to populate.
- Update relay filters to reduce local parsing + bandwidth.

Phase 2
- Add support for attachments metadata + “open in UI” deep links.

Acceptance criteria
- Latency: P95 <2s from TRAM create→local notification (same machine, normal network).
- Durability: if client is stopped for 1h, on restart it receives all unreads within 10s.
- Idle: no periodic polling/tool calls; only websocket keepalive traffic.
- Routing: FOR_SESSION messages never show as actionable on the wrong session; wrong-session ACK attempts blocked.
- Resource: relay <50MB RSS, one outbound websocket.

CONTEXT_AVAILABILITY: db=TRAM_ONLY; git=NO; local_files=NO; web=NO; provider_ui=NO
