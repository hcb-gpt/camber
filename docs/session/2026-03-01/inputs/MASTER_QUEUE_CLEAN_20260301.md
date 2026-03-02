# MASTER WORK QUEUE — Clean Slate
## 2026-03-01 05:00 UTC | All sessions retired | TRAM swept

---

## STATUS: What actually shipped tonight
- Triage Fix 2 (expand transcript): MERGED ✓
- Triage Fix 3 (swipe left → PICK): MERGED ✓
- Swipe sims CI (PR #260): MERGED ✓
- Beside parity view fix: DEPLOYED ✓
- Epic 1.2 backfill (~850 scheduler_items): DEPLOYED ✓
- NEEDS_SPLIT taxonomy (views + ai-router v1.20): DEPLOYED by dev-gemini-1 ✓
- review_resolutions + reprocess flag: DEPLOYED by dev-5 ✓
- Engineering Policies v1.0: COMMITTED (not merged, blocked by CI)
- Closed-loop training spec v1: WRITTEN + PEER REVIEWED (5 corrections applied)
- Gemini peer review policy: ENACTED

## STATUS: What is broken right now
1. **Beside app stale since Feb 26** — local DB on Chad's Mac not syncing
2. **Zapier SMS ingestion stopped Feb 28** — no new texts being ingested
3. **deno-ci failing** — 7 local commits can't push to origin/master
4. **PR #257 (time resolver) not merged** — blocks scheduler on master
5. **~850 TENTATIVE timestamps in scheduler_items** — should be NULL per Gemini review

---

## P0 — BROKEN / BLOCKING (fix before anything else)

### 1. FIX DENO-CI + PUSH 7 COMMITS TO MASTER
**What:** Protected branch check `deno-ci` is failing. 7 agent commits are stranded on Chad's local master.
**Commits:** context-assembly fix, engineering policies, backfill function, time resolver, merge conflicts
**Acceptance:** CI green, 7 commits on origin/master, chad-device synced
**Effort:** 30min
**Role:** DEV

### 2. RESTART BESIDE APP + FIX ZAPIER SMS
**What:** Beside (call recording app) hasn't synced since Feb 26. Zapier SMS ingestion stopped Feb 28. These are the data sources — if they're down, nothing new flows into CAMBER.
**Actions:**
- Check Beside app on Chad's Mac, restart if needed
- Check Zapier zap for SMS → sms_messages, re-enable
- Fix ambiguous `run_beside_parity_monitor_v1()` DB function (duplicate signatures)
- Move ingestion script to camber-calls/scripts/ per prior directive
**Acceptance:** New calls appearing in interactions within 1 hour. New SMS appearing in sms_messages.
**Effort:** 1hr (requires Chad's machine access for Beside)
**Role:** CHAD (Beside restart) + DEV (Zapier + DB function)

### 3. MERGE TIME RESOLVER TO MASTER (PR #257)
**What:** Epic 1.1 time_resolver.ts is done but not on master. Blocks Epic 1.2 merge and closed-loop time scoring.
**Branch:** codex/dev-5-synthetics-pack or merge/scheduler-integration
**Acceptance:** time_resolver.ts on origin/master
**Depends on:** #1 (CI must be green first)
**Effort:** 15min
**Role:** DEV

### 4. ROLLBACK TENTATIVE TIMESTAMPS
**What:** Gemini review says TENTATIVE confidence timestamps must not be in scheduler_items. ~850 rows were backfilled, unknown how many are TENTATIVE.
**Actions:**
```sql
-- Audit
SELECT count(*), confidence FROM time_resolution_audit GROUP BY confidence;
-- Rollback TENTATIVE rows
UPDATE scheduler_items si
SET start_at_utc = NULL, end_at_utc = NULL, due_at_utc = NULL
FROM time_resolution_audit tra
WHERE tra.scheduler_item_id = si.id
  AND tra.confidence = 'TENTATIVE';
```
**Acceptance:** Zero TENTATIVE-sourced timestamps in scheduler_items. Audit table preserved.
**Effort:** 15min
**Role:** DATA

---

## P1 — CLOSED-LOOP TRAINING (the learning flywheel)

### 5. STAGE 1: Ground Truth Table + is_synthetic
**What:** Create synthetic_ground_truth table with Gemini-reviewed schema. Add is_synthetic boolean to interactions.
**Schema:** (from Gemini review — includes expected_taxonomy_state, expected_span_count, expected_project_ids[])
```sql
CREATE TABLE synthetic_ground_truth (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id text NOT NULL,
  run_id uuid,
  expected_taxonomy_state text CHECK (expected_taxonomy_state IN ('SINGLE_PROJECT', 'NEEDS_SPLIT', 'UNKNOWN')),
  expected_project_ids text[],
  expected_contact_id uuid,
  expected_span_count int,
  difficulty text CHECK (difficulty IN ('easy','medium','hard','adversarial')),
  scenario_type text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE interactions ADD COLUMN IF NOT EXISTS is_synthetic boolean DEFAULT false;
UPDATE interactions SET is_synthetic = true WHERE interaction_id LIKE 'cll_SYNTH_%';
```
**Acceptance:** Table created. is_synthetic populated. 50+ scenario definitions documented.
**Depends on:** Nothing
**PEER_REVIEW_GATE:** Schema already Gemini-reviewed ✓
**Effort:** 2hr
**Role:** DEV

### 6. STAGE 2: Join Verification + is_synthetic Guards
**What:** Prove the full join chain works for synthetics. Audit every function that writes to affinity_ledger and document where is_synthetic guards are needed.
**Join chain:** synthetic_ground_truth → interactions → conversation_spans → span_attributions → triage_decisions
**Guard targets:** review-resolve, auto-review-resolver, any trigger that writes to affinity_ledger
**Acceptance:** SQL query proving chain. List of functions needing guards. Guards NOT yet implemented (just the audit).
**Depends on:** #5
**Effort:** 2hr
**Role:** DATA

### 7. STAGE 2b: Implement is_synthetic Guards
**What:** Hard-abort any writes to affinity_ledger or contact-project priors if is_synthetic = true.
**Acceptance:** Run a synthetic through the full pipeline. Verify affinity_ledger has zero new rows for synthetic contacts/projects.
**Depends on:** #6 (guard audit)
**Effort:** 1hr
**Role:** DEV

### 8. STAGE 5: Headless Scoring
**What:** Create scoring tables and edge function. Score at span level.
**Schema:** (from Gemini review — includes epistemic_entropy, evidence_support_gap, failed_to_split)
```sql
CREATE TABLE loop_run_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_label text NOT NULL,
  agent_mode text CHECK (agent_mode IN ('oracle', 'pipeline_trust', 'adversarial')),
  total_interactions int,
  attribution_accuracy numeric(5,4),
  multi_project_accuracy numeric(5,4),
  contact_resolution_accuracy numeric(5,4),
  confidence_calibration numeric(5,4),
  pipeline_drop_rate numeric(5,4),
  mean_latency_ms int,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE loop_run_details (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES loop_run_scores(id),
  interaction_id text NOT NULL,
  attribution_verdict text CHECK (attribution_verdict IN ('correct', 'wrong_project', 'missed', 'false_positive', 'failed_to_split')),
  pipeline_confidence numeric(5,4),
  epistemic_entropy numeric(5,4),
  evidence_support_gap numeric(5,4),
  agent_action text,
  created_at timestamptz DEFAULT now()
);
```
**Acceptance:** Tables created. score-loop-run edge function deployed. Can score a synthetic batch headlessly.
**Depends on:** #5, #7
**PEER_REVIEW_GATE:** Schema already Gemini-reviewed ✓
**Effort:** 4hr
**Role:** DEV

### 9. STAGE 4: Headless Agents (Oracle + Pipeline-Trust)
**What:** Backend scripts that evaluate pipeline output against ground truth. NOT iOS simulator.
**Acceptance:** Oracle agent scores 50+ synthetics. Pipeline-Trust agent scores same batch. Delta = error rate.
**Depends on:** #5, #7, #8
**Effort:** 4hr
**Role:** DEV

### 10. STAGE 6a + 6c: Error Catalog + Prompt Suggestions
**Depends on:** #8, #9
**Effort:** 3hr
**Role:** DEV + STRAT

---

## P2 — TRIAGE UX (Redline iOS app quality)

### 11. TRIAGE FIX 1: Comment Sheet Override
**Bug:** Can't change project while adding a note.
**Fix:** Make Resolve Target tappable → ProjectPickerSheet → atomic resolve.
**Files:** TriageCommentSheet.swift, TriageViewModel.swift
**Branch:** fix/triage/comment-sheet-override
**Effort:** 1hr | **Role:** DEV

### 12. TRIAGE FIX 4: Confidence Evidence (Gemini-reviewed)
**Rules:**
- Never show LLM reasoning. Deterministic anchors only.
- effective_confidence = max(0, ai_conf - entropy * W)
- NEEDS_SPLIT hides confidence → scissors icon
- Always show evidence, not just below 65%
**Files:** TriageCardView.swift, span_attributions.anchors
**Branch:** fix/triage/confidence-evidence
**Effort:** 2hr | **Role:** DEV

### 13. TRIAGE FIX 5: Progress Context
**What:** "2 done, 2 remaining of 4 today"
**Branch:** fix/triage/progress-context
**Effort:** 1hr | **Role:** DEV

### 14. TRIAGE FIX 6: Later Queue
**What:** Visible "Later" section, auto-reappear after 24h
**Branch:** fix/triage/later-queue
**Effort:** 2hr | **Role:** DEV

### 15. TRIAGE FIX 7: Multi-Project Phase A
**What:** Span-centric cards with "Topic 1 of 3", highlighted transcript segment, server-side queue state.
**NOTE:** Phase B (M2M table) is KILLED. Replacement = NEEDS_SPLIT taxonomy (already deployed by dev-gemini-1).
**Branch:** fix/triage/multi-project-phase-a
**Effort:** 3hr | **Role:** DEV

### 16. TRIAGE FIX 8: Contact Resolution
**What:** Tap "Unknown" to resolve caller identity.
**Branch:** fix/triage/contact-resolution
**Effort:** 2hr | **Role:** DEV

### 17. Freshness SLA (21-day cutoff)
**What:** No real triage cards older than 21 days in the app. Server-side filter.
**Acceptance:** Query showing 0 non-synthetic items older than cutoff in bootstrap-review feed.
**Effort:** 1hr | **Role:** DEV

---

## P3 — INFRASTRUCTURE

### 18. REMINDERS TABLE v2 (Gemini-reviewed)
**Corrections applied:** span_id ref (not char offsets), next_trigger_at flattened, plpgsql, 'overdue' status, target_deadline_at
**Branch:** feat/scheduler/reminders-table-v2
**PEER_REVIEW_GATE:** Already reviewed ✓
**Effort:** 2hr | **Role:** DEV

### 19. TIME RESOLVER FIXES (Gemini-reviewed)
**What:** Add window_start_utc/window_end_utc to scheduler_items. Fix Tue/Wed regex. TENTATIVE stops writing to scheduler_items.
**Branch:** fix/time-resolver-gemini-corrections
**PEER_REVIEW_GATE:** Already reviewed ✓
**Effort:** 3hr | **Role:** DEV

### 20. REPO ROOT CLEANUP
**What:** Delete ora remnants, consolidate docs, gitignore logs, clean gate_run files.
**Branch:** fix/repo-root-cleanup
**Effort:** 1hr | **Role:** DEV

### 21. BRANCH CLEANUP
**What:** Delete 94 merged remote branches. Prune 9 stale worktrees. Chad-approved.
**Effort:** 30min | **Role:** DEV

### 22. BOOT DOCS SSOT ALIGNMENT
**What:** Sync orbit docs IDs (b/r/rb/c = canonical, long names = aliases). Update CLAUDE.md boot instructions.
**Effort:** 2hr | **Role:** DEV

### 23. iOS E2E GATE → 5/5
**What:** Synthetics E2E gate currently at 1/5. 4 synthetics stall at segment-call or ai-router. Debug pipeline stall.
**Effort:** 4hr | **Role:** DEV

---

## P4 — OTHER PROJECTS (Chad to prioritize)

### 24. HEARTWOOD CONSTRUCTION
- Active builds: Hurley, Moss, Permar, Skelton, Winship, Woodbery, Young
- Permit coordination across GA counties
- Vendor management
- BuilderTrend integrations
- Timesheet automation
*Need Chad input on what's active / urgent here.*

### 25. LONG LEAD LENS (Procurement Intelligence)
- Status unknown. Is this still active?

---

## GEMINI PEER REVIEW TRACKER
| Spec | Reviewed | Corrections |
|------|----------|-------------|
| Closed-loop training v1 | ✓ 2 passes | 3 flaws fixed (simulator, poisoning, ouroboros) |
| Closed-loop schemas (Stage 1+5) | ✓ 2 passes | taxonomy_state, span scoring, entropy fields |
| Triage Fix 7 (multi-project) | ✓ 2 passes | M2M table killed → NEEDS_SPLIT |
| Reminders table | ✓ 2 passes | char offsets, trigger flattening, overdue status |
| Time resolver | ✓ 2 passes | TENTATIVE rollback, windows, disambiguation |
| Confidence evidence | ✓ 2 passes | No LLM reasoning, entropy penalty, scissors icon |

---

## POLICIES IN EFFECT
1. **Gemini Peer Review Gate** — any spec with schema/pipeline/scoring changes must be reviewed by Gemini 3.1 Pro before DEV dispatch
2. **Engineering Policies v1.0** — PR naming, proof bundles, branch protection (committed, not merged)
3. **1 Span = 1 Project** — foundational pipeline invariant, enforced by NEEDS_SPLIT taxonomy
4. **Synthetics never mutate priors** — is_synthetic guard required on all affinity_ledger writes
5. **Stage 6b KILLED** — no auto-adding facts from synthetic data, ever

---

## ESTIMATED EFFORT SUMMARY
| Priority | Items | Est. Hours |
|----------|-------|------------|
| P0 Blockers | 4 | 2hr |
| P1 Closed-Loop | 6 | 15hr |
| P2 Triage UX | 7 | 12hr |
| P3 Infrastructure | 6 | 12.5hr |
| **Total** | **23** | **~41.5hr** |

At 3 parallel devs, ~2 days of focused work to clear the queue.
