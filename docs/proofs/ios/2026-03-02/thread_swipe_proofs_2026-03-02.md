# iOS thread swipe proofs (2026-03-02)

These artifacts are intended to be a truth-forcing, git-committed SIM_PROOF of attribution write behavior.

## Fail-closed (no privileged auth)

- `edge_secret_present=0`
- Expected: confirm fails closed (`ok=false`) and UI shows write-locked banner.

Artifacts:
- `docs/proofs/ios/2026-03-02/thread_swipe_edge_secret0_smoke_markers_20260302T190719Z.log`
- `docs/proofs/ios/2026-03-02/thread_swipe_edge_secret0_write_locked_20260302T190719Z.png`

## Privileged (edge secret present)

- `edge_secret_present=1`
- Expected: confirm succeeds (`ok=true`) and undo succeeds (`ok=true`).

Artifacts:
- `docs/proofs/ios/2026-03-02/thread_swipe_edge_secret1_smoke_markers_20260302T190230Z.log`
