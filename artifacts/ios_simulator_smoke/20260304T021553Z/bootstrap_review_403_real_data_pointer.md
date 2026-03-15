# REAL_DATA_POINTER — bootstrap-review 401/403 lock evidence

## 403 sample A (real)
- log file: `artifacts/ios_simulator_smoke/20260303T054646Z/app.log`
- line: `3755`
- evidence: `Task <7E5CFA9E-E10B-438A-BF00-9BD4B2299B67>.<4> received response, status 403`
- paired lock banner with request-id (same run): line `3775`
- request_id: `019cb23c-fbe6-7020-bd4a-1dc08b02fbae`

## 403 sample B (real)
- log file: `artifacts/ios_simulator_smoke/20260303T205541Z/app.log`
- line: `76671`
- evidence: `Task <DF7BADD6-16A5-4B3E-8594-88E3ED5D7204>.<3> received response, status 403`
- paired auth lock metric (same run): line `76699`
- request_id: `019cb5cf-0dce-7ec4-bcf5-f39debd00cb7`

## Screenshot pointer (real)
- `artifacts/ios_simulator_smoke/2026-03-02/453737e_triage_locked_with_request_id.png`
