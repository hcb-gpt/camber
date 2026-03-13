# Redline Refresh Monitor TTL Cleanup

Date: 2026-03-12 UTC
Target receipt: directive__ceo__dev__redline_monitor_ttl_or_circuit_breaker__20260312T133431Z
Repo path: `camber`
Migration: `supabase/migrations/20260312143000_redline_refresh_monitor_ttl_circuit_breaker.sql`

## Change

- Added `cleanup_redline_refresh_monitor_alerts()` to dedupe stale redline refresh alerts, backfill a 2 hour TTL on the surviving active alert, and auto-resolve duplicate TRAM rows with `resolution='DEFERRED'`.
- Replaced `run_redline_refresh_monitor()` with a circuit-breaker version that:
  - keeps at most one active STRAT TRAM alert,
  - writes `expires_at = now() + interval '2 hours'` for new redline monitor alerts,
  - marks duplicate monitor rows as `alert_suppressed` instead of emitting another TRAM alert,
  - records cleanup counters in `metric_snapshot`.
- Applied the migration directly to the remote database and repaired migration history as `20260312143000 => applied`.

## Live Cleanup Result

Before apply:
- `tram_messages` with `subject='alert__redline_refresh_monitor_v1'` and `resolution is null`: `243`
- Same alert rows older than 6 hours: `207`
- Same alert rows older than 24 hours: `99`
- `monitor_alerts` with `monitor_name='redline_refresh_monitor_v1'` and `acked=false`: `292`

After apply:
- Open redline refresh TRAM alerts: `1`
- Open and unacked redline refresh TRAM alerts: `1`
- Deferred redline refresh TRAM alerts: `256`
- Open redline refresh alerts missing `expires_at`: `0`
- Unacked `monitor_alerts` rows for `redline_refresh_monitor_v1`: `1`
- Active receipt: `alert__redline_refresh_monitor_v1__82c000c7bd72`
- Active receipt expires at: `2026-03-12T16:20:00.19834+00:00`
- Latest monitor row status: `alert_suppressed`

## Suppression Probe

Manual probe:
- Call: `select public.run_redline_refresh_monitor(true, 'dev:ttl_probe')`
- Result status: `alert_suppressed`
- `tram_suppressed=true`
- `active_tram_receipt='alert__redline_refresh_monitor_v1__82c000c7bd72'`
- Open alert count before probe: `1`
- Open alert count after probe: `1`

The probe confirmed the monitor no longer emits a second STRAT alert while one active alert already exists.
