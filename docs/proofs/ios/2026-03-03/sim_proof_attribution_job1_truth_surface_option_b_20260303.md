# SIM Proof: Attribution Job1 + Truth Surface Option-B (2026-03-03)

## Artifacts
- `docs/proofs/ios/2026-03-03/attribution_surface_action_pills_20260303T190754Z.png`
  - Attribution action surface showing AI suggestion context with `Change` + `Confirm` action posture.
- `docs/proofs/ios/2026-03-03/contactlist_attribution_filter_and_triage_row_20260303T191540Z.png`
  - ContactList inbox showing `Attribution` filter pill and pinned `Attribution Triage` row.
- `docs/proofs/ios/2026-03-03/truth_graph_option_b_posture_20260303T191912Z.png`
  - Truth Graph Option-B read-only posture with CTA (`Reload Thread`; disabled `Refresh Truth Graph`).

## Build + Runtime Proof
- Build guard: `artifacts/xcodebuild_guard/20260303T190722Z/build.log`
- Smoke runs:
  - `artifacts/ios_simulator_smoke/20260303T190754Z` (truth-surface local pick/undo)
  - `artifacts/ios_simulator_smoke/20260303T190857Z` (write-lock recovery)
- KPI extracts:
  - `docs/proofs/ios/2026-03-03/learning_loop_kpi_events_20260303T190754Z.log`
  - `docs/proofs/ios/2026-03-03/learning_loop_kpi_events_20260303T190857Z.log`

## Event Evidence Highlights
- `PICK_TIME_SAMPLE` emitted with hashed queue/card identifiers.
- `UNDO_COMMIT` emitted on undo path with hashed queue identifier.
- `AUTH_LOCK_UI_DISABLED` emitted with `status_code=403` on lock-disabled surface.
