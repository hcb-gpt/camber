# Redline iOS Learning Loop (Truth-Forcing Surface) — Plan v1 (2026-03-02)

Design bar (customer-linked): **"You're not designing for yourself. You're designing for someone who doesn't have time to figure out what you built."**
Secondary bar (user-perceived value): **"The best features disappear. The user just feels like things got easier."**

## 0) Goal (User Benefit)
Redline iOS is not a “card viewer.” It is the **actuator** for the epistemic control loop:
- Prevent poisoned feedback (no mindless swipes / no forced lies).
- Make *the fastest correct action* also *the most truth-preserving action*.
- Turn every user action into a durable, auditable learning signal (or a durable repair request when substrate is broken).

## 1) Live Reality Check (Replace Opinions With Numbers)
### 1.1 Queue Forcing-State Mix (fresh window)
Source: `bootstrap-review?action=queue` (max_age_days=21, limit=100), classified into forcing states.

Captured run: **2026-03-02 19:33Z**
- Total queue items returned: `17`
- Forcing-state mix:
  - `PICK_REQUIRED`: `17` (100.0%)
  - `FAST_CONFIRM`: `0`
  - `NEEDS_SPLIT`: `0`
  - `PIPELINE_DEFECT`: `0`
- Truth graph lanes (reliability signal; only some lanes are blocking):
  - `unknown` (healthy): `10`
  - `journal` (non-blocking warning): `7`
- Dominant reason codes:
  - `weak_anchor`: 17
  - `quote_unverified`: 10
  - `geo_only`: 4
- Highest confidence observed: `0.65` (no `>= 0.92` auto-confirm candidates in this fresh window)
- Sample queue item (to make the datapoint concrete):
  - `review_queue_id`: `9583e897-c966-4a6a-b050-f851fe3eb557`
  - `interaction_id`: `cll_SYNTH_SYNTH_FLOATER_CONTIN_1772335530`
  - `reason_codes`: `["weak_anchor"]`
  - `confidence`: `0.25`

**Decision implied by this datapoint:** Next iOS truth-surface work should be **picker-first anti-anchoring UX**, not defect/repair UX and not split-span UX (those still matter, but are not the current bottleneck).

### 1.2 How to Reproduce (Real Data Pointer)
Run:
```bash
cd camber
source scripts/load-env.sh
deno run --allow-env --allow-net --allow-read scripts/triage_queue_bucket_mix_v1.ts
```

## 2) Forcing States (One UI Contract, No Ambiguity)
All triage surfaces (inbox + thread) must map each item into exactly one forcing state and then enforce the corresponding UI constraints:

| State | What it means | iOS must do (truth forcing) | Backend action |
|------|----------------|-----------------------------|----------------|
| `PICK_REQUIRED` | Model is weak / ambiguous; a default would anchor. | Do **not** preselect a project. Disable “confirm” swipe. Force explicit pick (fast). | `bootstrap-review?action=resolve` with chosen project (human lock). |
| `FAST_CONFIRM` | Model is strongly confident *and* substrate is healthy. | Allow 1-gesture confirm, but show a minimal deterministic “receipt” (no LLM reasoning). | `resolve` (human lock) + optional QA sampling. |
| `NEEDS_SPLIT` | Span likely contains multiple projects; single label would be a lie. | Hard-block assignment. Require “Mark as multi-project” action. (v1: no interactive splitting.) | v1: set `NEEDS_SPLIT` + enqueue replay; v2: interactive sentence split. |
| `PIPELINE_DEFECT` | Truth graph shows missing/stale substrate in *blocking lanes* (process-call / segment-call / ai-router). | Replace card with defect block + 1-tap repair action; prevent assignment. | `redline-thread?action=repair` (idempotent). |

### 2.1 Shared UI Primitives (STRAT iOS finesse, canonical)
These primitives apply across all forcing states (feed + thread):
- Badges must be **truth-first**: never imply “done” when pipeline is uncertain.
- Use 3-state chips everywhere: `Pending` (gray), `Ready` (blue), `Blocked` (red).
- When an action is disabled:
  - keep the affordance **visible but locked**
  - tap explains *why* it’s locked (hiding actions creates false mental models)

Empty states (canonical copy):
- No evidence yet: “Waiting for evidence.” + secondary: “This may take a few minutes.”
- Blocked by pipeline defect: “Blocked by pipeline defect.” + CTA: “Repair pipeline”
- Needs split: “This thread mixes topics.” + CTA: “Split thread”

## 3) Learning Loop Forcing Functions (Grounded in Current Surfaces)
This section is the “Gemini 3.1 forcing functions” translated into current repo reality.

### 3.1 Human Lock (The +1.0 update primitive)
Current reality: the iOS app can already write durable “human lock” decisions via `bootstrap-review` (resolve/dismiss/undo) when Internal Mode is enabled (Keychain-held `X-Edge-Secret`).

iOS truth-surface requirements:
- Every resolve must surface **an auditable receipt** (request_id / queue_id) in UI (non-scary, but copyable in DEBUG builds).
- Every resolve must support *Undo* (already supported) to reduce fear and increase throughput.

Decision-linked metric:
- `undo_rate`: if > 5% daily, UI is too easy to mis-tap or too ambiguous; fix interaction design before adding complexity.

### 3.2 Anti-Anchoring (Preserve ground truth)
Default posture: **hide “AI reasoning.”** Only show deterministic receipts that do not steer the human into agreeing.

Implementation v1 (based on live queue mix = 100% weak anchors):
- If `confidence < 0.92` OR reason includes `weak_anchor`:
  - Show “Pick project” UI as primary.
  - AI suggestion can be shown as a small “Suggested” chip, but never preselected.
  - “Confirm swipe” is disabled; only explicit pick enables submit.

Optional stronger anti-anchoring (recommended if drift persists):
- Show the current label as “Hypothesis” until Evidence Tokens ≥ threshold.
- Never display a definitive grade without a confidence chip.

Decision-linked metric:
- `pick_time_p50` / `pick_time_p90`: if p90 > 20s, picker UX is too slow (add search/recents/chips), not more model complexity.

### 3.3 Truth Graph Block (Refuse to mask substrate failures)
Backend already exposes `redline-thread?action=truth_graph&interaction_id=...` and an idempotent repair hook.

Implementation v1:
- Add truth-graph gating to triage cards:
  - If truth graph indicates a *blocking* non-healthy lane (process-call/segment-call/ai-router), show defect block and disable assignment.
  - If truth graph lane is `journal`, show a small non-blocking warning (still allow human lock writes).
  - Provide 1-tap repair action (`repair_process_call` or `repair_ai_router`) with status feedback.

Decision-linked metric:
- `pipeline_defect_rate`: if > 2% of triage feed over 24h, stop iOS UX work and fix pipeline reliability first.
- `journal_missing_rate`: if > 20% daily, prioritize journaling reliability (but do not block attribution labeling on it).

### 3.4 NEEDS_SPLIT (Prevent multi-project corruption)
Current live queue shows 0 `NEEDS_SPLIT`, but we still need the forcing behavior before it appears.

Phased approach:
- v1: **hard-block** + “Mark multi-project (NEEDS_SPLIT)” + “Replay pipeline” (no interactive splitting UI).
- v2: interactive sentence-level splitting (true corrective labeling).

STRAT iOS UX notes for v2 split:
- Primary action: `Split` / “Split thread” (not “scissor”)
- Two-step flow: choose boundary → confirm
- Confirmation copy: “Split creates two threads. You can undo immediately.”

Decision-linked metric:
- `needs_split_rate`: if > 5% weekly, prioritize v2 splitting UX.

### 3.5 QA Unblocker (Truth-check high-confidence automation)
Future-proof the loop so auto-assignments don’t silently learn from themselves.

Implementation idea:
- Divert a small random sample of high-confidence auto-assignments into Redline with reason `qa_sample_auto_assign`.
- Only after a human confirms should the backend apply low-weight priors.

Decision-linked metric:
- `qa_fail_rate`: if > 2% on audited auto-assignments, raise the auto-assign threshold or change model features; do not increase automation volume.

## 4) iOS UX Plan (Learning Loop = Job 1)
### 4.1 What to ship next (based on live numbers)
Because the queue is currently dominated by weak anchors:
1. **Picker-first triage** that is fast enough that users don’t “fight the tool.”
2. **Anti-anchoring defaults** (no preselect, no confirm swipe for weak items).
3. **Receipts not reasoning** (deterministic evidence only).

### 4.1.1 Evidence Tokens (UI/UX finesse)
Evidence Tokens should be visible but non-anchoring:
- Show as compact chips with count + freshness (example: `3 tokens · 2m`)
- Tap → sheet with:
  - token list + timestamps
  - 1-line “why this matters”
This enables users to move quickly without “trusting the model’s story.”

Concrete iOS touchpoints:
- `camber/ios/CamberRedline/CamberRedline/Views/AttributionTriageCardsView.swift`
  - Gate swipe gestures by forcing state (not just `writesLocked`).
- `camber/ios/CamberRedline/CamberRedline/ViewModels/CardTriageViewModel.swift`
  - Centralize forcing-state computation and UI enable/disable behavior.
- `camber/ios/CamberRedline/CamberRedline/Services/BootstrapService.swift`
  - Ensure resolve payload can carry “AI guessed X but human chose Y” (runner-up punishment later).
- `camber/ios/CamberRedline/CamberRedline/Services/SupabaseService.swift`
  - Integrate truth graph fetch (already present) into triage gating.

### 4.2 Evidence Receipt UI (v2, high leverage)
Add “Evidence receipts” that train deterministic labeling functions:
- Show *which deterministic receipts fired* (alias match, geo-only, quote-unverified).
- When human overrides, optionally capture “what text implies the correct project” (highlight token).

Backend landing zone (existing building blocks):
- `suggested_aliases` table exists and can receive proposals.
- `override_log` already tracks from/to values; extend with “evidence receipt” later.

## 5) Metrics That Force Decisions (No Theater)
Only track metrics where the next decision is explicit:
- `pick_required_rate`:
  - If > 50% weekly: invest in picker speed + evidence receipts (not automation).
- `fast_confirm_rate`:
  - If < 10% weekly: don’t spend time on “confirm swipe polish” yet.
- `override_rate` (human chose != AI guess):
  - If > 30% weekly: model is drifting; pause UI expansion and fix candidate generation.
- `pipeline_defect_rate` (truth graph not healthy):
  - If > 2% daily: prioritize repair automation and/or ingestion reliability.
- `queue_age_p90`:
  - If p90 > 48h: pipeline freshness SLA is failing; stop product work and repair ops.

## 6) Proof + Shipping Discipline (So Chad Can See It)
Every iOS PR that changes the truth surface includes:
- `USER_BENEFIT:` 1 sentence, user-visible.
- `REAL_DATA_POINTER:` queue_id / interaction_id / request_id(s) exercised (redacted secrets).
- `GIT_PROOF:` merge SHA.
- `SIM_PROOF:` screenshots committed under `camber/artifacts/ios_simulator_smoke/YYYY-MM-DD/...`.

Open integration: Strat iOS is producing a parallel UI/UX finesse plan; this doc is meant to be updated with their specific interaction design choices once received.

Canonical copy strings (suggested SSOT):
- “Waiting for evidence.”
- “Blocked by pipeline defect.”
- “Repair pipeline”
- “This thread mixes topics.”
- “Split thread”
- “Evidence tokens”
- “Override (expert)” (gate behind confirmation)
