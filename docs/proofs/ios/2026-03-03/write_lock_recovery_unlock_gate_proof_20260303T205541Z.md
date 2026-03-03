# iOS Write Lock Recovery Unlock Gate Proof (2026-03-03)

## Scope
- Task receipt: `action_item__ios__fix_recover_write_access_unlock_gate__20260303T204701Z`
- Goal: keep writes locked on non-success recovery responses; unlock only on explicit success.

## Code Changes
- `ios/CamberRedline/CamberRedline/Services/BootstrapService.swift`
  - `recoverWriteAccess()` now unlocks only when probe response matches explicit success contract.
  - Non-auth failure / parse failure now returns `.failed(...)` and preserves lock state.
  - Added recovery probe payload parser and explicit success helper:
    - success when `2xx && ok=true`
    - success when `404 && error_code=item_not_found` (UUID sentinel probe)
  - Added `SMOKE_RECOVERY_PROBE_QUEUE_ID` override + UUID default probe queue id.
  - Added smoke-only forced lock (`SMOKE_FORCE_WRITE_LOCK=1`) for deterministic simulator regression.

- `ios/CamberRedline/CamberRedline/Views/AttributionTriageCardsView.swift`
  - Added `--smoke-write-lock-recovery` automation lane.
  - Emits recovery-specific markers for locked state, result, abort/retry.

- `scripts/ios_simulator_smoke_drive.sh`
  - Added `--write-lock-recovery` and `--recovery-probe-queue-id`.
  - Passes SIMCTL env vars required for deterministic lock/recovery checks.

- `scripts/ios_write_lock_recovery_regression.sh`
  - Added two-case regression harness.

## Regression Command
```bash
./scripts/ios_write_lock_recovery_regression.sh
```

## Regression Results
- Harness summary: `artifacts/ios_write_lock_recovery_regression/20260303T205541Z/summary.txt`

### Case 1: non-auth failure preserves lock
- Smoke run: `artifacts/ios_simulator_smoke/20260303T205541Z/`
- Marker evidence (`smoke_markers.log`):
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RESULT unlocked=0 wait_seconds=15`
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_ABORT reason=still_locked`

### Case 2: explicit success unlocks
- Smoke run: `artifacts/ios_simulator_smoke/20260303T205654Z/`
- Marker evidence (`smoke_markers.log`):
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RESULT unlocked=1 wait_seconds=0`
  - `SMOKE_EVENT WRITE_LOCK_RECOVERY_RETRY ...`

## Artifacts
- Case 1 video: `artifacts/ios_simulator_smoke/20260303T205541Z/session.mp4`
- Case 2 video: `artifacts/ios_simulator_smoke/20260303T205654Z/session.mp4`
- Case 1 summary: `artifacts/ios_write_lock_recovery_regression/20260303T205541Z/non_auth_failure_preserves_lock.summary.txt`
- Case 2 summary: `artifacts/ios_write_lock_recovery_regression/20260303T205541Z/explicit_success_unlocks.summary.txt`
