# iOS realtime cleanup proof (2026-03-02)

Goal: prove that realtime subscribe failure paths tear down channels (`claim_grades`, `review_queue`) so the iOS truth surface doesn't silently stall due to stale channel references.

## How to run

```bash
cd camber
bash scripts/ios_simulator_smoke_realtime_cleanup_proof.sh
```

## Expected markers

- `SMOKE_EVENT REALTIME_CLEANUP_PROOF_START`
- `SMOKE_EVENT REALTIME_CLEANUP_PROOF claim_grades_cleanup_ok=true`
- `SMOKE_EVENT REALTIME_CLEANUP_PROOF thread_interactions_removed_review_queue=1`
- `SMOKE_EVENT REALTIME_CLEANUP_PROOF thread_interactions_channels_cleared=true`
- `SMOKE_EVENT REALTIME_CLEANUP_PROOF contactlist_removed_review_queue=1`
- `SMOKE_EVENT REALTIME_CLEANUP_PROOF_END`

## Artifacts

- `docs/proofs/ios/2026-03-02/realtime_cleanup_smoke_markers_20260302T203454Z.log`
