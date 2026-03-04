# iOS Write-Lock Recovery Regression Proof (2026-03-03)

## Scope
Fix `BootstrapService.recoverWriteAccess()` so write lock is only cleared on explicit recovery success, and remains locked on non-auth failures.

## Code Changes
- `ios/CamberRedline/CamberRedline/Services/BootstrapService.swift`
  - Recovery probe now uses UUID sentinel `00000000-0000-0000-0000-000000000000` by default.
  - Unlock now requires explicit success contract:
    - `2xx` with `ok=true`, or
    - `404` with `error_code=item_not_found` (auth gate passed for UUID probe).
  - Non-auth failures now preserve lock and return `.failed(...)`.
  - Added KPI log `KPI_EVENT AUTH_LOCK_RECOVERY_PRESERVED`.
  - Added debug regression env override `SMOKE_RECOVERY_PROBE_QUEUE_ID`.
- `scripts/ios_simulator_smoke_drive.sh`
  - Added `--recovery-probe-queue-id` and summary field `recovery_probe_queue_id`.
  - Passes `SIMCTL_CHILD_SMOKE_RECOVERY_PROBE_QUEUE_ID` to simulator app.
- `scripts/ios_write_lock_recovery_regression.sh`
  - Runs two regression scenarios and hard-fails if expected markers are missing.

## Regression Runs
Command:

```bash
./scripts/ios_write_lock_recovery_regression.sh
```

Run root:
- `artifacts/ios_write_lock_recovery_regression/20260303T205128Z`

### Case 1: Non-auth failure preserves lock
- Smoke run: `artifacts/ios_simulator_smoke/20260303T205129Z`
- Probe override: `SMOKE_RECOVERY_PROBE_QUEUE_ID=__invalid_recovery_probe__`
- Expected: lock stays on (`unlocked=0`)
- Observed markers:
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RESULT unlocked=0 wait_seconds=15`
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_ABORT reason=still_locked`
- KPI observed:
  - `KPI_EVENT AUTH_LOCK_RECOVERY_PRESERVED status_code=400 ... error_code=missing_review_queue_id`

### Case 2: Explicit success unlocks
- Smoke run: `artifacts/ios_simulator_smoke/20260303T205254Z`
- Probe: default UUID sentinel (no override)
- Expected: lock clears (`unlocked=1`)
- Observed markers:
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RESULT unlocked=1 wait_seconds=0`
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RETRY ...`
- KPI observed:
  - `KPI_EVENT AUTH_LOCK_RECOVERY_UNLOCKED status_code=404 ...`

## SIM_PROOF Artifacts
- `docs/proofs/ios/2026-03-03/write_lock_recovery_regression_non_auth_locked_20260303T205129Z.png`
- `docs/proofs/ios/2026-03-03/write_lock_recovery_regression_explicit_success_unlocked_20260303T205254Z.png`
- `docs/proofs/ios/2026-03-03/write_lock_recovery_regression_non_auth_markers_20260303T205129Z.log`
- `docs/proofs/ios/2026-03-03/write_lock_recovery_regression_success_markers_20260303T205254Z.log`
- `docs/proofs/ios/2026-03-03/write_lock_recovery_regression_kpi_events_20260303T205254Z.log`

