# iOS SIM_PROOF (stub): picker-first truth surface v1

This is a placeholder proof artifact for the WIP PR.

For an automation-backed proof run (screenshots + smoke markers), see:
- `picker_first_truth_surface_v1_proof.md`

Expected UI deltas on `AttributionTriageCardsView`:
- No preselect: cards start with `Pick required` even when an AI suggestion exists.
- Confirm (right-swipe) is disabled until a project is picked and evidence tokens exist.
- 3-state readiness chip: Pending / Ready / Blocked.
- Evidence chip shows token count + freshness; tap opens the Evidence sheet.

Image placeholder: `picker_first_truth_surface_v1_stub.png` (will be replaced with a real sim screenshot).
