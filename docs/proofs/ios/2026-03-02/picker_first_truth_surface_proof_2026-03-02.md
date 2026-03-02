# iOS picker-first truth surface proof (2026-03-02)

Goal: prove the attribution triage “truth-forcing” surface is picker-first (no silent anchoring), is informative (evidence + reasons visible), and is feedback-affordant (clear blocked/ready/pending states + write-lock request IDs).

## How to run

Bundle: `com.heartwoodcustombuilders.CamberRedline`

### 1) Static UX proofs (no network dependencies)

- No preselect + confirm locked until explicit pick:
  - Launch args: `--smoke-triage-static`
- Auto-open Evidence sheet:
  - Launch args: `--smoke-triage-static --smoke-triage-open-evidence`

### 2) Smoke drive (captures write-lock + request_id)

- Launch args: `--smoke-drive --smoke-triage-keep-undo`
- Expected marker:
  - `SMOKE_EVENT TRIAGE_WRITE_LOCKED ... request_id: <id>`

## Artifacts

- `picker_first_no_preselect_confirm_locked.png`: picker-first gating (no preselect; confirm remains locked until a user explicitly picks a project).
- `picker_first_evidence_sheet.png`: Evidence chip opens the Evidence sheet (anchors/reasons surfaced).
- `picker_first_undo_requestid_p90.png`: activity rail shows `pick p90`; writes-locked banner includes `function_version` + `request_id`.
- `picker_first_smoke_markers_20260302T214541Z.log`: smoke markers for the run (includes `TRIAGE_WRITE_LOCKED` + `request_id`).

