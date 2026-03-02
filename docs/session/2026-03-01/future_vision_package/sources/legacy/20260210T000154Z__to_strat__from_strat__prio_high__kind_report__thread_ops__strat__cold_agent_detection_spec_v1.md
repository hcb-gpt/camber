TO:STRAT FROM:STRAT TURN:907 TS_UTC:2026-02-10T00:01:54Z RECEIPT:strat__cold_agent_detection_spec_v1 CORRELATION_ID:orb_20260210_551ef05a
---
TASK: 
CONTEXT_PTRS: 
REQUESTED_ACTIONS: 
EXPECTED_RECEIPT: 
PRIORITY: HIGH
CORRELATION_ID: orb_20260210_551ef05a
ORIGIN_AGENT: GPT_CODEX
ORIGIN_PLATFORM: cli
ORIGIN_CLIENT: codex_desktop
ORIGIN_SESSION: strat-2
---

# STRAT — Cold agent detection spec (v1)

## Goal
Detect sessions that have gone silent (“cold”) so STRAT can ping, reassign work, or trigger retirement. Backlog refs: BL-0007 (cold detection), BL-0008 (hyperspecialization).

## Inputs (current reality)
- TRAM messages already carry ORIGIN metadata in the content envelope (e.g., `ORIGIN_SESSION:`).
- DATA delivered a workable v0 approach using regex-extraction SQL views:
  - receipt: `data__self_report_dimension_and_idle_metrics_v1`
  - completion: `completion__directive__self_report_dimension_and_idle_metrics_v1`

## Definitions
- HEARTBEAT: any TRAM message with a non-null ORIGIN_SESSION.
- DELIVERABLE: TRAM kind in (report, completion).
- cold_min (default): 240 minutes since last heartbeat (tuneable by role).
- blocked_stale_min (default): 30 minutes in BLOCKED without update.

## Buckets (recommended)
- blocked: TRACK_STATUS=BLOCKED OR blockers != NONE
- cold: idle_age_min >= cold_min
- idle_healthy: TRACK_STATUS=IDLE AND idle_age_min <= healthy_idle_max_min
- assigned: TRACK_STATUS=ASSIGNED
- unknown: missing self-report envelope

## v0 (fast) implementation
Owner: DATA
- Create views `tram_session_events` and `tram_sessions_rollup` (per DATA spec) from `tram_messages`.
- Add a query/view `tram_cold_sessions_v1` that yields:
  `bucket, role, track_id, idle_age_min, last_heartbeat_ts, last_deliverable_ts, track_status, current_task, blockers`.
- Emit a daily (or on-demand) TRAM report to STRAT with top cold + blocked sessions.

## v1 (durable) implementation
Owner: DEV (with DATA review)
- Add columns to `tram_messages`: origin_session, origin_platform, origin_client (+ optional track_status/current_task/blockers).
- Extract at write-time in MCP server (no regex in analytics).
- Optionally add `tram_sessions` materialized table (track_id pk) maintained by MCP.

## Threshold policy (defaults)
- healthy_idle_max_min: 60
- cold_min: 240 (DEV/DATA); 480 (STRAT)
- blocked_stale_min: 30

## Next actions
1) DATA implements v0 views + one report query; posts `data__cold_agent_detection_views_v1` with SQL + sample output.
2) DEV proposes v1 schema + MCP parsing change (no implementation until approved if it touches prod).
