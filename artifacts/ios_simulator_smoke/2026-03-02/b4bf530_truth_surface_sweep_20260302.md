# iOS truth-surface sweep (2026-03-02)

- `GIT_SHA`: `b4bf5303c6e0999896a0a86d282413e4869f2203`
- `interaction_id`: `cll_SYNTH_SYNTH_FLOATER_CONTIN_1772335530`
- `queue_id` (from smoke logs): `9583e897-c966-4a6a-b050-f851fe3eb557`

## Smoke Drive (`--smoke-drive`)

Run stamp: `20260302T183418Z`

Expected behavior (no privileged auth): **writes fail closed** and show the write-lock banner.

Artifacts:
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_shot_01.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_shot_02.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_shot_03.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_smoke_markers.log`
  - Contains: `TRIAGE_WRITE_LOCKED` banner (bootstrap-review `v1.3.2`, request_id `019cafd5-e240-794e-88c3-df50eecd151b`).
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_smoke_drive_20260302T183418Z_summary.txt`

## Thread Swipe (`--smoke-thread-swipe`)

### `edge_secret_present=0`

Run stamp: `20260302T182830Z`

Expected behavior: confirm **fails closed** (`ok=false`).

Artifacts:
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_thread_swipe_edge_secret0_20260302T182830Z_smoke_markers.log`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_thread_swipe_edge_secret0_20260302T182830Z_summary.txt`

### `edge_secret_present=1`

Run stamp: `20260302T183154Z`

Expected behavior: confirm **succeeds** (`ok=true`) and undo **succeeds** (`ok=true`).

Artifacts:
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_thread_swipe_edge_secret1_20260302T183154Z_smoke_markers.log`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_thread_swipe_edge_secret1_20260302T183154Z_summary.txt`

## Truth Graph Demo (`--truth-graph-demo`)

Run stamp: `20260302T183637Z`

Expected behavior: Truth Graph status card loads and shows hydrated tables.

Artifacts:
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_truth_graph_demo_20260302T183637Z_shot_01.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_truth_graph_demo_20260302T183637Z_shot_02.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_truth_graph_demo_20260302T183637Z_shot_03.png`
- `artifacts/ios_simulator_smoke/2026-03-02/b4bf530_truth_graph_demo_20260302T183637Z_summary.txt`

