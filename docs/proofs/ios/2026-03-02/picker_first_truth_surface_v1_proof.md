# iOS SIM_PROOF: picker-first truth surface v1 (automation-backed)

## What this proves

1. **No preselect**: even when an AI suggestion exists, the card starts in **Pending** with **Pick required**.
2. **Confirm is truth-forced**: the user must explicitly pick a project (here we simulate picking the AI suggestion) before the UI reaches **Ready**.
3. **Evidence token surface**: the Evidence chip shows **token count + freshness**, and evidence is present.

## Evidence (screenshots)

- Unpicked (Pending): `picker_first_truth_surface_v1_unpicked.png`
- Picked (Ready): `picker_first_truth_surface_v1_ready.png`

## Repro (1 command)

From repo root:

```bash
scripts/ios_simulator_smoke_drive.sh --truth-surface-local
```

That launches the app with:
- `--smoke-drive` (open triage sheet automatically)
- `--smoke-truth-surface` (exercise the truth surface stages)
- `--smoke-truth-surface-local` (local synthetic queue; no network/auth dependency)

## Proof log markers

See: `picker_first_truth_surface_v1_smoke_markers_20260302T211747Z.log`

Expected sequence:
- `SMOKE_EVENT TRIAGE_LOCAL_QUEUE_READY items=1`
- `SMOKE_EVENT TRUTH_SURFACE_STAGE stage=unpicked selected=missing`
- `SMOKE_EVENT TRUTH_SURFACE_STAGE stage=picked ... evidence_count=1`
- `SMOKE_EVENT TRUTH_SURFACE_CONFIRM_LOCAL ...`
