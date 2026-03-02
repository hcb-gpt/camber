# Beside Parity Report — Redline iOS (2026-03-02)

SSOT: **Beside** app UX/navigation model (right side of Chad-provided screenshot).  
Redline current app: **CamberRedline iOS** (left side of screenshot).

This report is **Inbox-first** (primary daily workflow). “Parity” here means: if a Beside user opens Redline, they can orient instantly and accomplish the same core jobs, while Redline preserves **truth-forcing** (explain missing evidence + route repair, not silent failure).

---

## What the team sees (Redline left vs Beside right)

1) **Primary navigation**
- Beside: 5 tabs (Inbox / Calls / AI / Dial / Settings).
- Redline (screenshot): 3-tab pill (Redline / Triage / Assistant).
- Redline (current code): 5-tab shell already exists (see pointers below). Remaining work is parity polish and truth-surface integration.

2) **Search = omnibox**
- Beside: “Search or Ask Beside AI”.
- Redline (screenshot): “Search”.
- Redline (current code): prompt already updated to “Search or Ask Redline AI”.

3) **Inbox filters are explicit**
- Beside: filter pills “All / Unread / Ask Beside AI”.
- Redline (screenshot): no filter row.
- Redline (current code): pills row exists; “Unread” is a placeholder mapping to triage pressure.

4) **Pinned AI entry in the list**
- Beside: pinned “Ask Beside AI” conversation row (distinct visual identity).
- Redline (screenshot): none.
- Redline (current code): pinned “Ask Redline AI” row exists.

5) **Row hierarchy: identity first, attention second**
- Beside: avatar initials + name + snippet + time, with subtle unread indicators.
- Redline (screenshot): large numeric “ungraded” bubble dominates the avatar position.
- Redline (current code): still foregrounds ungraded count as the “avatar” (needs change to match Beside feel while retaining truth-signal as a smaller badge).

6) **Quick action affordances**
- Beside: inline call icon per row (and call icon in thread header).
- Redline (screenshot): no inline row actions; thread actions exist but were historically “not wired”.
- Redline (current code): thread header “Call” is wired; row-call is not yet part of the UI baseline.

7) **Truth surface**
- Beside: user sees “conversation UI”; missing pipeline evidence is not a concept.
- Redline: must make missing evidence *visible* and *actionable* (Truth Graph status + repairs) without confusing this with “Unread”.

---

## Current implementation pointers (ground truth)

These exist on `camber` `master` today:
- 5-tab shell + triage-as-internal-mode sheet: `ios/CamberRedline/CamberRedline/CamberRedlineApp.swift`
- Inbox pills row + pinned “Ask Redline AI” row + omnibox prompt: `ios/CamberRedline/CamberRedline/Views/ContactListView.swift`
- Thread header Call wired to `tel://` and Info opens a sheet: `ios/CamberRedline/CamberRedline/Views/ThreadView.swift`
- Remaining parity gap: row identity vs triage signal: `ios/CamberRedline/CamberRedline/Views/ContactRow.swift`

---

## Parity matrix (machine-actionable)

| Feature | Beside (SSOT) | Redline iOS status (code) | Backend data needed | Owner | Acceptance test |
|---|---|---|---|---|---|
| 5-tab navigation shell | Inbox/Calls/AI/Dial/Settings | **DONE** (`CamberRedlineApp.swift`) | none | Team 3 (FE) | App launches; 5 tabs render; no crash |
| Triage is internal mode | not top-level | **DONE** (sheet reachable from Inbox/AI) | review queue endpoints | Team 3 (FE) | Smoke drive reaches triage + AI via routes |
| Omnibox prompt | “Search or Ask … AI” | **DONE** (`ContactListView.swift`) | none | Team 3 (FE) | Prompt text matches; search works |
| Filter pills | All/Unread/Ask AI | **DONE** (Unread placeholder) | real `unread_count` (or explicit `triage_count`) | Team 2 (BE) + Team 3 (FE) | Pills switch list deterministically |
| Pinned AI row | “Ask … AI” | **DONE** | none | Team 3 (FE) | Tap routes to AI tab |
| Row avatar initials (not triage number) | initials + subtle badge | **TODO** (`ContactRow.swift`) | none | Team 3 (FE) | Avatar shows initials; badge shows triage pressure |
| Inline row call affordance | call icon per row | **TODO** (blocked on above + `contact.phone`) | `contact.phone` present (nullable) | Team 2 (BE) + Team 3 (FE) | Call icon appears when phone exists; tap does not navigate |
| Row preview snippet consistency | stable snippet | **PARTIAL** (`last_summary` → `lastSnippet`) | `last_summary` consistent + direction/type | Team 2 (BE) | Rows show meaningful preview on all contacts |
| Thread header call + info | call + info | **DONE** | `contact.phone` | Team 3 (FE) | Call opens dialer; Info sheet opens |
| Truth Graph status card | explain missing evidence + repair | **TODO** (still banner) | Truth Graph endpoint (`redline-thread?action=truth_graph`) + `suggested_repairs` payload (repair writes admin-only) | Team 2 (BE) + Team 3 (FE) | Missing evidence never hidden; repair routes exist (internal-only) |

---

## Top 10 user-value deltas (sequenced)

1) **Row identity-first** (initials avatar) + **truth badge second** (triage count)  
   Why: makes Inbox scannable like Beside while still truth-forcing.

2) **Inline call affordance** (when phone exists)  
   Why: turns Inbox into action surface; matches Beside muscle memory.

3) **Truth ≠ Unread** (separate `triage_count` vs unread)  
   Why: prevents semantic corruption; keeps user trust.

4) **Snippet quality** (`last_summary` stable)  
   Why: “what happened last” must be reliable.

5) **Thread header parity** (Call + Info always wired)  
   Why: removes “dead buttons” and restores trust.

6) **Truth Graph status card** (internal toggle)  
   Why: turns pipeline gaps into actionable repair, not hidden defects.

7) **Calls tab v0 meaningful** (even if minimal list)  
   Why: Beside parity; users expect a call-centric view.

8) **Settings tab: build + pipeline status**  
   Why: internal tool needs “am I broken?” at a glance.

9) **Large-screen split view (stretch)**  
   Why: iPad/Mac Catalyst parity with Beside; productivity.

10) **Parity monitors for regressions**  
   Why: prevent slide-back; keep SSOT alignment explicit.

---

## Backend dependency requests (for Team 2)

DEPENDENCY_REQUEST (Inbox parity):
- NEED: `contact.phone` (nullable) + explicit `triage_count` (or `unread_count`) + consistent `last_summary` field.
- WHY: to match Beside row affordances and avoid overloading “Unread”.
- ACCEPTANCE: sample JSON payload + iOS decode proof (no fallback path for common case).
- DEADLINE: ASAP (blocks row-call affordance and correct semantics).

DELIVERED (Truth surface contract):
- `GET redline-thread?action=truth_graph&interaction_id=<id>` is available and anon-key readable (no client edge secret; Option B posture).
- Payload includes `hydration`, `lane`, `warnings`, and `suggested_repairs` (with `idempotency_key`); repair execution remains admin-only.
