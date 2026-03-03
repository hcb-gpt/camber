# iOS Internal Mode + Truth Surface v1 Proof (2026-03-03)

## Build + Simulator proof
- Truth-surface smoke run: `artifacts/ios_simulator_smoke/20260303T124610Z`
- Write-lock recovery smoke run: `artifacts/ios_simulator_smoke/20260303T124818Z`
- Build logs:
  - `artifacts/ios_simulator_smoke/20260303T124610Z/build.log`
  - `artifacts/ios_simulator_smoke/20260303T124818Z/build.log`

## Truth-surface markers (picker-first)
From `docs/proofs/ios/2026-03-03/truth_surface_markers_20260303T124610Z.log`:
- `TRUTH_SURFACE_STAGE stage=unpicked selected=missing`
- `TRUTH_SURFACE_STAGE stage=picked project=...`
- `TRIAGE_ACTION kind=resolve ... request_id=stub_resolve__...`
- `TRIAGE_ACTION kind=undo ... request_id=stub_undo__...`

## Internal-mode auth gate markers
From `docs/proofs/ios/2026-03-03/write_lock_recovery_markers_20260303T124818Z.log`:
- `WRITE_LOCK_RECOVERY_LOCKED ... request_id: smoke-forced-lock`
- `WRITE_LOCK_RECOVERY_RESULT unlocked=1`
- `TRIAGE_ACTION kind=resolve ... request_id=019cb3be-e229-70e2-93c8-6c88c917dd53`
- `TRIAGE_ACTION kind=undo ... request_id=019cb3be-ec15-76b7-b5b9-a5fa6fb3eeb0`

## Real-data pointer (direct bootstrap-review calls)
- Blocked write without `X-Edge-Secret`: `403`, `sb-request-id=019cb3c0-54ed-7d55-9dca-99bbaa01b884`
- Successful write with `X-Edge-Secret`: `200`, `sb-request-id=019cb3c0-5652-7a1b-a6ad-2860349ae850`
- Successful undo with `X-Edge-Secret`: `200`, `sb-request-id=019cb3c0-5d32-7a7a-b936-f93546d2a043`

## Artifacts in this folder
- PNG screenshots showing unpicked/picked truth surface and write-lock recovery transitions.
- MP4 recordings for both runs.
- Raw smoke summaries + markers.
