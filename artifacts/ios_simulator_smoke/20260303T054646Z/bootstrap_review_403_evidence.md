# bootstrap-review 401/403 mitigation evidence (iOS)

## REAL_DATA_POINTER

1. **Request ID** `019cb23c-fbe6-7020-bd4a-1dc08b02fbae`
- Source log: `artifacts/ios_simulator_smoke/20260303T054646Z/smoke_markers.log` (line contains `SMOKE_EVENT TRIAGE_WRITE_LOCKED`).
- Observed banner copy: `Attribution writes temporarily locked. Truth surface remains readable.`
- Screenshot (same run, locked card state): `artifacts/ios_simulator_smoke/20260303T054646Z/screens/shot_01.png`

2. **Request ID** `019cafd5-e240-794e-88c3-df50eecd151b`
- Source log: `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_smoke_markers.log` (line contains `SMOKE_EVENT TRIAGE_WRITE_LOCKED`).
- Screenshot with request-id visible in UI: `artifacts/ios_simulator_smoke/2026-03-02/453737e_triage_locked_with_request_id.png`

## BUILD_PROOF

- Fresh simulator smoke/build summary:
  - `artifacts/ios_simulator_smoke/20260303T054646Z/summary.txt`
- Build log:
  - `artifacts/ios_simulator_smoke/20260303T054646Z/build.log` (generated in run, not committed due size)
