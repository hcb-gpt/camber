# iOS Write-Lock Recovery Proof Pack (PR380)

Source run: `artifacts/ios_simulator_smoke/20260303T064025Z`

## What this pack contains
- `screens/shot_01.png` .. `screens/shot_14.png`
- `smoke_markers.log`
- `summary.txt`
- `request_id_extract.log`

## Key proof pointers
- Lock shown (401/403 fail-closed state visible):
  - `screens/shot_01.png`
  - `request_id_extract.log` line containing `AUTH_LOCK_SET status_code=403` with request id `019cb278-8139-71ff-8590-f85a0193833e`
- Recovery unlock probe:
  - `request_id_extract.log` line containing `AUTH_LOCK_RECOVERY_UNLOCKED status_code=400` with request id `019cb26d-c279-70b7-ae3d-5c7b47f2889d`
- Post-recovery write retry:
  - `request_id_extract.log` line containing `TRIAGE_ACTION kind=resolve ... request_id=019cb26d-d9f3-7413-9e54-dc9c49d01a17`
- Recovery sheet / unlocked state screenshots:
  - `screens/shot_02.png`
  - `screens/shot_04.png`
