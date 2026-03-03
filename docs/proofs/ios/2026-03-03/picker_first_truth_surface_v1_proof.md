# iOS SIM_PROOF: picker-first anti-anchoring truth surface v1 (2026-03-03)

## Acceptance coverage

1. **No preselected project + commit blocked until explicit pick**
   - `picker_first_truth_surface_v1_unpicked.png`
   - Shows `Pending`, `Pick required`, no selected project, and confirm swipe still blocked.

2. **Explicit pick enables commit**
   - `picker_first_truth_surface_v1_ready.png`
   - Shows `Ready` only after explicit pick event.

3. **Post-write toast with Undo + deterministic receipt (DEBUG)**
   - `picker_first_truth_surface_v1_saved_undo_receipt.png`
   - Shows `Saved`, `Undo`, and compact receipt with `Copy receipt`.

4. **Video proof**
   - `picker_first_truth_surface_v1_smoke_20260303T055401Z.mp4`

5. **Automation markers**
   - `picker_first_truth_surface_v1_smoke_markers_20260303T055401Z.log`
   - Includes:
     - `TRUTH_SURFACE_STAGE stage=unpicked selected=missing`
     - `TRUTH_SURFACE_STAGE stage=picked ...`
     - `TRIAGE_ACTION kind=resolve ... request_id=stub_resolve__rq_smoke_truth_surface_v1`
     - `TRIAGE_ACTION kind=undo ... request_id=stub_undo__rq_smoke_truth_surface_v1`

## Repro

```bash
scripts/ios_simulator_smoke_drive.sh --truth-surface-local
```

Smoke run summary: `picker_first_truth_surface_v1_smoke_summary_20260303T055401Z.txt`.
