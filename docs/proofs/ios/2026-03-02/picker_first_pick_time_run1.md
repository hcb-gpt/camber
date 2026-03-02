# Picker-first throughput proof (Run 1)

**Date:** 2026-03-02
**Mode:** iOS simulator smoke (targeted synthetic IDs)
**Artifacts:**
- `picker_first_pick_time_run1.mp4`
- `picker_first_pick_time_run1_1.png`
- `picker_first_pick_time_run1_2.png`
- `picker_first_pick_time_run1_3.png`
- `picker_first_pick_time_run1_smoke_markers.log`

## Timing measurement

Definition used: `target_at` = first `SMOKE_EVENT TRIAGE_TARGET` timestamp; `commit_at` = `SMOKE_EVENT TRIAGE_ACTION kind=resolve|dismiss` timestamp (post network write).

| # | interaction_id | kind | target_at | commit_at | latency_sec | request_id |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `cll_SYNTH_SYNTH_FLOATER_CONTIN_1772335530` | resolve | `2026-03-02 15:27:02.102` | `2026-03-02 15:27:03.852` | `1.750` | `019cb03b-9ae2-7490-bd60-0d61ed804af6` |
| 2 | `cll_SYNTH_SYNTH_STOPLINE_NO_PR_1772335634` | dismiss | `2026-03-02 15:27:21.221` | `2026-03-02 15:27:21.802` | `0.581` | `019cb03b-e56f-7752-9cc8-d31f22dbbd3b` |
| 3 | `cll_SYNTH_SYNTH_HOMEOWNER_OVER_1772335530` | resolve | `2026-03-02 15:27:37.630` | `2026-03-02 15:27:39.431` | `1.801` | `019cb03c-2558-7986-8512-e9a80c7bb7fd` |
| 4 | `cll_SYNTH_SYNTH_COMMON_ALIAS_O_1772335530` | dismiss | `2026-03-02 15:28:02.443` | `2026-03-02 15:28:03.048` | `0.605` | `019cb03c-8654-7336-865a-5dbf965328da` |
| 5 | `cll_SYNTH_SYNTH_NAME_COINCIDEN_1772335530` | resolve | `2026-03-02 15:28:17.129` | `2026-03-02 15:28:18.735` | `1.606` | `019cb03c-bfb4-7de7-8f91-a9b345f0219f` |
| 6 | `cll_SYNTH_SYNTH_FLOATER_CONTIN_1772335448` | resolve | `2026-03-02 15:28:34.146` | `2026-03-02 15:28:36.115` | `1.969` | `019cb03d-0225-74a3-835e-e4d5e67a6616` |
| 7 | `cll_SYNTH_SYNTH_STOPLINE_NO_PR_1772335530` | dismiss | `2026-03-02 15:28:54.478` | `2026-03-02 15:28:55.075` | `0.597` | `019cb03d-51ad-7a85-baff-22c1f150cff0` |
| 8 | `cll_SYNTH_SYNTH_HOMEOWNER_OVER_1772335448` | resolve | `2026-03-02 15:29:05.582` | `2026-03-02 15:29:06.968` | `1.386` | `019cb03d-7ce7-7098-8268-5597a8052daf` |
| 9 | `cll_SYNTH_SYNTH_COMMON_ALIAS_O_1772335448` | dismiss | `2026-03-02 15:29:21.443` | `2026-03-02 15:29:26.658` | `5.215` | `019cb03d-baed-7fc0-830c-a959e61a4a9e` |
| 10 | `cll_SYNTH_SYNTH_NAME_COINCIDEN_1772335448` | resolve | `2026-03-02 15:29:46.670` | `2026-03-02 15:29:48.271` | `1.601` | `019cb03e-1d6a-7644-99d2-0172777ce067` |

## Summary

- samples: 10/10
- pick_time_p90_sec (target→commit): 1.969
- queue_read_failure_count (markers): 0
- queue_read_failure_rate (markers): 0/10 = 0.000

## Notes

- Runs in smoke mode against synthetic queue items; each iteration performs resolve/dismiss + undo to avoid persistent queue mutation.
- This measures system + network latency, not human “think time”.
