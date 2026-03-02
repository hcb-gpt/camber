# Picker-first throughput proof (Run 1)

**Date:** 2026-03-02  
**Session:** `codex-dev-session`  
**Command:** `scripts/ios_simulator_smoke_drive.sh`  
**Launch args:** `--smoke-drive`  
**Device:** iPhone simulator `F27127D7-C087-4351-AF3A-7A57D1E1635C`  
**Artifacts:**
- `picker_first_pick_time_run1.mp4`
- `picker_first_pick_time_run1_1.png`
- `picker_first_pick_time_run1_2.png`
- `picker_first_pick_time_run1_3.png`
- `picker_first_pick_time_run1_smoke_markers.log`

## Timing measurement

| Item # | interaction_id | target_at | resolve_at | latency_sec |
| --- | --- | --- | --- | --- |
| 1 | `cll_SYNTH_SYNTH_FLOATER_CONTIN_1772335530` | `2026-03-02 14:45:47.486` | `2026-03-02 14:45:47.486` | `0.0` |

## Notes

- Current smoke automation path (`runSmokeSwipes`) only processes one triage card per invocation (target + resolve/dismiss + optional undo), so this run captured a single PICK_REQUIRED item.
- No code changes were made for this task; this is proof packaging and timing capture only.
