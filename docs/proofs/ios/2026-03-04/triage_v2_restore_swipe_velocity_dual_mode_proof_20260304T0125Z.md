# iOS Triage v2 Proof — Swipe Velocity + Dual Mode

UTC generated: 2026-03-04T01:25:00Z

## Scope validated
- Swipe right confirms suggested project in one gesture.
- Wrong-project path opens picker and picker selection auto-confirms.
- Write-locked mode blocks confirm/wrong/escalate with `Read-only right now` alert.
- `Ask me later` remains available while locked.
- `Recover` opens recovery sheet while locked.
- Relative-time formatter boundary tests pass.

## Artifacts
- Swipe dual-mode video: `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/session.mp4`
- Swipe dual-mode GIF: `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/session.gif`
- Swipe flow logs:
  - `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/step1_swipe_right.log`
  - `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/step2_undo.log`
  - `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/step3_wrong_project.log`
  - `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/step4_picker_select.log`
  - `docs/proofs/ios/2026-03-04/triage_v2_swipe_dual_mode_20260304T011726Z/screen_picker.json`
- Write-lock video: `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/session.mp4`
- Write-lock GIF: `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/session.gif`
- Write-lock screenshots:
  - `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/screens/01_after_swipe_right.png`
  - `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/screens/02_after_swipe_left.png`
  - `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/screens/03_after_swipe_up.png`
  - `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/screens/04_after_ask_me_later.png`
  - `docs/proofs/ios/2026-03-04/triage_v2_write_lock_20260304T012303Z/screens/05_after_recover.png`

## Test evidence
- Command:
  - `xcodebuild -project ios/CamberRedline/CamberRedline.xcodeproj -scheme CamberRedline -destination 'id=F27127D7-C087-4351-AF3A-7A57D1E1635C' -derivedDataPath artifacts/xcodebuild_tests/derived CODE_SIGNING_ALLOWED=NO -only-testing:CamberRedlineTests/TriageRelativeTimeFormatterTests test`
- Result: `** TEST SUCCEEDED **`
- Log: `artifacts/xcodebuild_tests/test_after_final_patch.log`

## Notes
- Picker blank-sheet bug was observed and fixed by adding a fallback card source when presenting `ProjectPickerSheet`.
- Proof captures were recorded on iPhone 17 Pro simulator (UDID `F27127D7-C087-4351-AF3A-7A57D1E1635C`).
