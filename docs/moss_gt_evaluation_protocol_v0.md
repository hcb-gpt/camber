# Moss Residence World Model GT Evaluation Protocol v0

**Status:** DRAFT
**Date:** 2026-02-16
**Owner:** CHAD (design) / DATA (execution)
**Scope:** Before/after evaluation of `project_facts` seeding for Moss Residence
**Pilot project_id:** `47cb7720-9495-4187-8220-a8100c3b67aa`

---

## 0) Context and Problem Statement

The Moss Residence is the pilot project for the world model facts integration. Current state:

- **32 interactions** in the pipeline associated with Moss
- **23 span attributions** exist for Moss-related calls
- **Only 5/23 reached `assign`** (78% stuck in `review`; `llm_weak_anchor` is the dominant reason code)
- **0 project_facts** currently seeded for Moss
- **~25 facts** ready to seed from plan-set extraction (`scripts/backfills/moss_residence_seed_v0.sql`)
- **8 existing GT labels**, 4 evaluable against current pipeline output
- **1 known misattribution:** `cll_06E0P6KYB5V7S5VYQA8ZTRQM4W` was attributed to Moss when GT says Hurley
- **1 known reverse misattribution:** `cll_06E09H1BF9R1VAGJ6ZGBSRY3E8` was attributed to Moss@0.75 when GT says Winship (Chris Gaugler = roofing sub, phase-incongruent)

### What we are testing

The `world_model_facts.ts` guardrail in `ai-router` uses seeded `project_facts` to:
1. Provide corroboration context in the LLM prompt (via `buildWorldModelFactsCandidateSummary`)
2. Apply a post-LLM guardrail (`applyWorldModelReferenceGuardrail`) that can downgrade `assign` to `review` when:
   - No strong fact anchor is present (`world_model_fact_weak_only`)
   - A fact contradicts the transcript (`world_model_fact_contradiction`)

The hypothesis is that seeding Moss-specific facts (address, features, materials, contacts) will:
- Give the LLM stronger project-discriminating signals in the context pack
- Allow the guardrail to validate or reject Moss attributions based on factual corroboration
- Reduce spurious `review` outcomes where the pipeline currently lacks confidence

---

## A) Baseline Metrics (BEFORE seeding facts)

### A.1 Metrics to capture per span

For every span in the Moss GT manifest, record:

| Field | Source | Description |
|-------|--------|-------------|
| `interaction_id` | manifest | Call identifier |
| `span_index` | manifest | Span position within call |
| `expected_project` | manifest (GT label) | Ground truth project name |
| `expected_decision` | manifest | `assign` / `none` / `review` |
| `predicted_project` | `span_attributions.project_id` -> `projects.name` | Pipeline's predicted project |
| `predicted_decision` | `span_attributions.decision` | `assign` / `review` / `none` |
| `predicted_confidence` | `span_attributions.confidence` | 0.0-1.0 confidence score |
| `reason_codes` | `span_attributions.reason_codes` (if available) or inferred from `needs_review` | Array of reason codes (e.g., `llm_weak_anchor`, `world_model_fact_contradiction`) |
| `candidate_rank` | context-assembly output (if logged) | Where the GT project ranked among candidates |
| `applied_project_id` | `span_attributions.applied_project_id` | Non-null only if decision=assign and write succeeded |
| `world_model_facts_in_context` | `false` for baseline | Whether project_facts appeared in the context pack |
| `model_id` | `span_attributions.model_id` | Which model version produced this attribution |
| `prompt_version` | `span_attributions.prompt_version` | Which prompt version was used |
| `attributed_at` | `span_attributions.attributed_at` | Timestamp of attribution |

### A.2 Aggregate metrics to compute

**Primary metrics:**

| Metric | Formula | Description |
|--------|---------|-------------|
| `review_rate` | `count(decision='review') / total_spans` | Fraction stuck in review |
| `assign_rate` | `count(decision='assign') / total_spans` | Fraction reaching assign |
| `none_rate` | `count(decision='none') / total_spans` | Fraction with no attribution |
| `overall_accuracy` | `count(correct) / total_spans` | Correct = GT matches predicted (project + decision) |
| `assign_accuracy` | `count(correct AND decision='assign') / count(decision='assign')` | Accuracy among assigned spans |
| `confidence_accuracy` | see below | Calibration metric |
| `misattribution_rate` | `count(predicted_project != expected_project AND decision='assign') / count(decision='assign')` | Wrong-project assigns |
| `staff_leak_rate` | `count(predicted_project IN staff_names) / total_spans` | Staff name leaks (target: 0) |

**Confidence calibration:**

For each confidence bucket (0.0-0.5, 0.5-0.7, 0.7-0.85, 0.85-1.0), compute:
- `bucket_accuracy` = correct / total within that confidence range
- Flag: `high_confidence_wrong` = spans where `confidence >= 0.75 AND NOT correct`

**Reason code distribution:**

Count occurrences of each reason code across all Moss-relevant spans:
- `llm_weak_anchor`
- `llm_no_project`
- `world_model_fact_contradiction`
- `world_model_fact_weak_only`
- (any others observed)

### A.3 Baseline snapshot query

```sql
-- Baseline: Moss-relevant attributions before fact seeding
-- Run BEFORE applying moss_residence_seed_v0.sql

WITH moss_spans AS (
  SELECT
    cs.id AS span_id,
    cs.interaction_id,
    cs.span_index,
    cs.transcript_segment,
    cs.segment_generation
  FROM conversation_spans cs
  WHERE cs.is_superseded = false
    AND cs.interaction_id IN (
      -- Populate with Moss GT manifest interaction_ids
      SELECT DISTINCT interaction_id
      FROM (VALUES
        -- INSERT MOSS GT INTERACTION IDS HERE
      ) AS v(interaction_id)
    )
),
latest_attr AS (
  SELECT DISTINCT ON (sa.span_id)
    sa.span_id,
    sa.project_id,
    sa.decision,
    sa.confidence,
    sa.applied_project_id,
    sa.needs_review,
    sa.model_id,
    sa.prompt_version,
    sa.attributed_at,
    sa.journal_references,
    p.name AS project_name
  FROM span_attributions sa
  LEFT JOIN projects p ON p.id = sa.project_id
  ORDER BY sa.span_id, sa.attributed_at DESC NULLS LAST, sa.id DESC
)
SELECT
  ms.interaction_id,
  ms.span_index,
  la.project_name AS predicted_project,
  la.project_id AS predicted_project_id,
  la.decision AS predicted_decision,
  la.confidence AS predicted_confidence,
  la.applied_project_id,
  la.needs_review,
  la.model_id,
  la.prompt_version,
  la.attributed_at,
  0 AS project_facts_count  -- always 0 for baseline
FROM moss_spans ms
LEFT JOIN latest_attr la ON la.span_id = ms.span_id
ORDER BY ms.interaction_id, ms.span_index;
```

Save output to: `artifacts/gt/runs/moss_baseline_<UTC>/baseline_snapshot.csv`

---

## B) Post-Seed Metrics (AFTER seeding + enabling WORLD_MODEL_FACTS_ENABLED)

### B.1 Same span-level metrics as Section A

Capture the identical metrics table from A.1, but now also record:

| Additional Field | Source | Description |
|-----------------|--------|-------------|
| `world_model_facts_in_context` | `true` / `false` | Did `project_facts` rows for any candidate appear in context pack? |
| `world_model_references_count` | ai-router log or `span_attributions` metadata | How many world_model_references did the LLM return? |
| `world_model_strong_anchor` | guardrail output | Did the guardrail find a strong fact anchor? |
| `world_model_contradiction` | guardrail output | Did the guardrail detect a fact contradiction? |
| `world_model_downgraded` | guardrail output | Was the decision downgraded from assign to review by the guardrail? |
| `world_model_reason_code` | guardrail output | `world_model_fact_contradiction` or `world_model_fact_weak_only` or null |
| `facts_matched_to_transcript` | manual inspection | Which specific facts appeared corroborative? |

### B.2 Decision-change analysis

For each span, compute:

| Comparison | Description |
|------------|-------------|
| `decision_changed` | `baseline_decision != post_seed_decision` |
| `decision_upgraded` | Changed from `review`/`none` to `assign` |
| `decision_downgraded` | Changed from `assign` to `review`/`none` |
| `decision_stable` | No change |
| `project_changed` | `baseline_project_id != post_seed_project_id` |
| `confidence_delta` | `post_seed_confidence - baseline_confidence` |

### B.3 Specific sentinel checks

These are binary pass/fail checks that must appear in every post-seed report:

**CHECK-1: Hurley misattribution corrected**
- Call: `cll_06E0P6KYB5V7S5VYQA8ZTRQM4W`
- Baseline: attributed to Moss (WRONG)
- GT: Hurley
- PASS condition: post-seed attribution is NOT Moss (ideally Hurley, or review)
- WHY: World model facts for Moss should NOT corroborate this call, potentially leading to review or correct attribution

**CHECK-2: Winship/Moss confusion corrected**
- Call: `cll_06E09H1BF9R1VAGJ6ZGBSRY3E8`
- Baseline: attributed to Moss@0.75 (WRONG; Chris Gaugler = roofing sub = Winship)
- GT: Winship
- PASS condition: post-seed attribution is NOT Moss
- WHY: Moss facts (Bishop GA, crawlspace foundation, McKenzie Drafting) should not corroborate a roofing sub call

**CHECK-3: Weak anchor upgrade rate**
- Population: all Moss spans where baseline `reason_code` includes `llm_weak_anchor`
- PASS condition: at least 30% of these spans move from `review` to `assign` with correct project
- WHY: Facts provide the "strong anchor" that was previously missing

**CHECK-4: No new misattributions introduced**
- Population: all spans in the GT manifest
- PASS condition: `post_seed_misattribution_count <= baseline_misattribution_count`
- WHY: Facts should reduce misattributions, not create new ones. If a span that was correctly assigned becomes misattributed, that is a regression.

**CHECK-5: Staff-name leak class absent**
- PASS condition: `staff_leak_rate == 0` in post-seed run
- WHY: Staff name blocklisting was a prior fix; facts should not re-introduce this class

**CHECK-6: No NOW-leakage in fact retrieval**
- Run `scripts/sql/proofs/project_facts_now_leakage_template.sql` for each Moss interaction
- PASS condition: all facts used in context packs satisfy KNOWN_AS_OF(t_call) filtering
- WHY: World model architecture v0 (Section 2.2 N2) requires KNOWN_AS_OF as default

---

## C) Success Criteria

### C.1 Primary success gate (all must pass)

| Criterion | Threshold | Rationale |
|-----------|-----------|-----------|
| `review_rate` decreases | Baseline review_rate - post_seed review_rate >= 10pp | Core hypothesis: facts reduce review pile-up |
| `assign_accuracy` does not regress | post_seed assign_accuracy >= baseline assign_accuracy | Facts must not degrade correct assignments |
| `misattribution_count` does not increase | post_seed misattributions <= baseline misattributions | Zero new wrong-project assigns |
| CHECK-1 passes | Hurley misattribution NOT attributed to Moss | Known regression must be fixed |
| CHECK-4 passes | No new misattributions | Safety gate |
| CHECK-5 passes | staff_leak_rate == 0 | No staff-name leak reappearance |
| CHECK-6 passes | No NOW-leakage | Anti-leakage compliance |

### C.2 Secondary success indicators (desirable but not blocking)

| Indicator | Target | Description |
|-----------|--------|-------------|
| `confidence_calibration_improves` | High-conf-wrong count decreases | Fewer overconfident wrong answers |
| `weak_anchor_upgrade_rate >= 30%` | CHECK-3 | Facts resolve ambiguity |
| `assign_rate` increases | post_seed assign_rate > baseline assign_rate | More spans reach final attribution |
| `confidence_delta > 0` for correct spans | Mean confidence increases for correct assignments | Evidence-backed confidence |
| CHECK-2 passes | Winship/Moss confusion resolved | Phase-incongruent attribution fixed |
| `contamination_rate == 0` | J0 contamination clean | No reviewish spans leak into journal_claims |

### C.3 Failure modes to watch for

| Failure Mode | Detection | Response |
|--------------|-----------|----------|
| Facts cause over-attribution to Moss | Spans from non-Moss calls get attributed to Moss | Tighten fact-to-transcript matching in guardrail |
| Guardrail is too aggressive | Correct Moss attributions get downgraded to review | Review `hasStrongFactAnchor` thresholds |
| Same-call exclusion broken | Facts derived from the call being attributed appear in its own context | Bug in `filterProjectFactsForPrompt` interaction_id filter |
| NOW-leakage | Future-knowledge facts included in historical reprocessing | KNOWN_AS_OF filter not applied or misconfigured |
| Confidence deflation | All confidence scores drop uniformly | Facts adding noise rather than signal |

---

## D) Evaluation Procedure (Runbook)

### D.0 Prerequisites

- [ ] `source ~/.camber/credentials.env` (provides `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `EDGE_SHARED_SECRET`)
- [ ] `source scripts/load-env.sh` (if using psql-based queries)
- [ ] Confirm Moss project exists: `SELECT id, name FROM projects WHERE id = '47cb7720-9495-4187-8220-a8100c3b67aa';`
- [ ] Confirm 0 project_facts for Moss: `SELECT count(*) FROM project_facts WHERE project_id = '47cb7720-9495-4187-8220-a8100c3b67aa';`
- [ ] GT manifest file exists and is populated with Moss-relevant interaction_ids

### D.1 Build the Moss GT Manifest

Create a manifest CSV at `artifacts/gt/manifests/gt_manifest_moss_pilot_v0.csv` with columns:

```
interaction_id,span_index,expected_project,expected_decision,anchor_quote,bucket_tags,notes,labeled_by,labeled_at_utc
```

**Source interaction_ids:** All 32 Moss interactions. For each:
1. Query current spans: `SELECT span_index, left(transcript_segment, 200) FROM conversation_spans WHERE interaction_id = '<id>' AND is_superseded = false ORDER BY span_index;`
2. Chad labels each span with `expected_project` and `expected_decision`
3. Tag each row with bucket_tags:
   - `bucket:moss_pilot` (all rows)
   - `bucket:weak_anchor` (if baseline reason_code includes `llm_weak_anchor`)
   - `bucket:misattribution` (if baseline prediction is wrong project)
   - `bucket:correct_baseline` (if baseline is already correct)
   - `bucket:multi_project` (if the call spans multiple projects)

**Known sentinel rows (must be in manifest):**
- `cll_06E0P6KYB5V7S5VYQA8ZTRQM4W` (Hurley misattributed as Moss)
- `cll_06E09H1BF9R1VAGJ6ZGBSRY3E8` (Winship misattributed as Moss)

### D.2 Run Baseline (Phase 1)

**Step 1: Capture baseline snapshot**

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber

# Run the eval harness with --skip-reseed to capture current state
python3 scripts/gt_evalharness_self_score_v1.py \
  --manifest artifacts/gt/manifests/gt_manifest_moss_pilot_v0.csv \
  --skip-reseed \
  --out-dir artifacts/gt/runs/moss_baseline_$(date -u +%Y%m%dT%H%M%SZ)
```

**Step 2: Verify baseline run**
- Check `summary.json` for `headline.review_rate` (expect ~0.78 based on known 18/23 in review)
- Check `rows.jsonl` for per-span detail
- Record the `run_id` as `MOSS_BASELINE_RUN_ID`

**Step 3: Register baseline in GT registry**

```bash
python3 scripts/gt_registry_update_from_manifest_v1.py \
  --manifest artifacts/gt/manifests/gt_manifest_moss_pilot_v0.csv
```

**Step 4: Capture project_facts count (expect 0)**

```sql
SELECT count(*) AS moss_facts_count
FROM project_facts
WHERE project_id = '47cb7720-9495-4187-8220-a8100c3b67aa';
```

### D.3 Seed Project Facts (Phase 2)

**Step 1: Review the seed script**

File: `scripts/backfills/moss_residence_seed_v0.sql`

Verify:
- `project_id` is `47cb7720-9495-4187-8220-a8100c3b67aa`
- `as_of_at` is `2025-09-01T04:00:00Z` (before any Moss calls in the pipeline)
- All facts have `evidence_event_id` provenance
- Script ends with `ROLLBACK` (safe by default)

**Step 2: Dry-run the seed**

```bash
# Run with ROLLBACK (default) to see what would be inserted
psql "$DATABASE_URL" -f scripts/backfills/moss_residence_seed_v0.sql
```

Verify the verification SELECT output shows ~25 rows across these fact_kinds:
- `scope.site` (5 rows)
- `scope.dimension` (10 rows)
- `scope.feature` (4 rows)
- `scope.material` (7 rows)
- `scope.contact` (3 rows)

**Step 3: Apply the seed (COMMIT)**

Edit `scripts/backfills/moss_residence_seed_v0.sql`:
- Change final `ROLLBACK;` to `COMMIT;`

```bash
psql "$DATABASE_URL" -f scripts/backfills/moss_residence_seed_v0.sql
```

**Step 4: Verify seed applied**

```sql
SELECT fact_kind, count(*) AS cnt
FROM project_facts
WHERE project_id = '47cb7720-9495-4187-8220-a8100c3b67aa'
GROUP BY fact_kind
ORDER BY fact_kind;
```

Expected: ~25 total rows.

**Step 5: Run provenance hygiene check**

```bash
# No half-pointers
scripts/query.sh "$(cat scripts/sql/proofs/project_facts_missing_provenance.sql)"
```

Expected: 0 rows with missing provenance.

### D.4 Enable World Model Facts and Reseed (Phase 3)

**Step 1: Verify WORLD_MODEL_FACTS_ENABLED**

Check that the ai-router Edge Function has the env var:
```
WORLD_MODEL_FACTS_ENABLED=true
```

If not set, this must be deployed by DEV before proceeding.

**Step 2: Reseed Moss interactions through the pipeline**

Use `admin-reseed` with the following parameters for each Moss interaction:

```bash
# For each interaction_id in the Moss manifest:
python3 scripts/gt_evalharness_self_score_v1.py \
  --manifest artifacts/gt/manifests/gt_manifest_moss_pilot_v0.csv \
  --out-dir artifacts/gt/runs/moss_postseed_$(date -u +%Y%m%dT%H%M%SZ)
```

The eval harness will:
1. Call `admin-reseed` with `mode=reseed_and_close_loop` for each interaction
2. Wait for the pipeline to re-process (segmentation -> context-assembly -> ai-router)
3. Read back the new `span_attributions` rows
4. Score against the GT manifest

**admin-reseed parameters used by the harness:**
- `mode`: `reseed_and_close_loop`
- `reason`: `gt_evalharness_self_score_v1`
- `idempotency_key`: `gt-evalharness-<run_id>-<interaction_id>`

**Step 3: Handle human-locked spans**

If any spans have `attribution_lock = 'human'`, the reseed will return HTTP 409 with `error_code=human_lock_present`. These spans:
- Cannot be reseeded automatically
- Must be noted as `infra_write_failure` in the report
- Should be excluded from before/after comparison (they are already correct by definition)

### D.5 Compare Before/After (Phase 4)

**Step 1: Load both run summaries**

```bash
# Baseline
cat artifacts/gt/runs/moss_baseline_<BASELINE_RUN_ID>/summary.json | python3 -m json.tool

# Post-seed
cat artifacts/gt/runs/moss_postseed_<POSTSEED_RUN_ID>/summary.json | python3 -m json.tool
```

**Step 2: Compute deltas**

For a manual comparison, compute these deltas using the two `summary.json` files:

```
review_rate_delta_pp     = baseline.review_rate - postseed.review_rate   (positive = improvement)
assign_rate_delta_pp     = postseed.assign_rate - baseline.assign_rate   (positive = improvement)
accuracy_delta_pp        = postseed.overall_accuracy - baseline.overall_accuracy
misattrib_delta          = postseed.misattrib_count - baseline.misattrib_count (negative or 0 = good)
staff_leak_delta         = postseed.staff_leak_rate - baseline.staff_leak_rate (must be 0)
```

**Step 3: Per-span diff**

Join `baseline/rows.jsonl` and `postseed/rows.jsonl` on `(interaction_id, span_index)`:

```python
# Pseudocode for span-level diff
for (iid, si) in all_spans:
    b = baseline_row(iid, si)
    p = postseed_row(iid, si)

    emit {
        "interaction_id": iid,
        "span_index": si,
        "baseline_decision": b.predicted_decision,
        "postseed_decision": p.predicted_decision,
        "baseline_project": b.predicted_project,
        "postseed_project": p.predicted_project,
        "baseline_confidence": b.predicted_confidence,
        "postseed_confidence": p.predicted_confidence,
        "baseline_correct": b.correct,
        "postseed_correct": p.correct,
        "decision_changed": b.predicted_decision != p.predicted_decision,
        "improved": not b.correct and p.correct,
        "regressed": b.correct and not p.correct,
    }
```

**Step 4: Run sentinel checks**

- CHECK-1: Find `cll_06E0P6KYB5V7S5VYQA8ZTRQM4W` in postseed rows. Is `predicted_project` NOT Moss?
- CHECK-2: Find `cll_06E09H1BF9R1VAGJ6ZGBSRY3E8` in postseed rows. Is `predicted_project` NOT Moss?
- CHECK-3: Count spans tagged `bucket:weak_anchor` where `baseline_decision='review'` and `postseed_decision='assign'` and `postseed_correct=true`. Divide by total `bucket:weak_anchor` spans.
- CHECK-4: Count `regressed` spans (baseline correct, postseed incorrect). Must be 0.
- CHECK-5: `staff_leak_rate` in postseed summary. Must be 0.
- CHECK-6: Run NOW-leakage template for each Moss interaction. All facts must be AS_OF, not POST_HOC.

**Step 5: Run contamination check**

```sql
-- J0 contamination for Moss interactions (windowed to post-seed run)
WITH target_spans AS (
  SELECT cs.id AS span_id, cs.interaction_id, cs.span_index
  FROM conversation_spans cs
  WHERE cs.interaction_id IN (
    -- INSERT MOSS INTERACTION IDS
  )
  AND cs.is_superseded = false
),
latest_attr AS (
  SELECT DISTINCT ON (span_id)
    span_id, decision, applied_project_id, attributed_at
  FROM span_attributions
  ORDER BY span_id, attributed_at DESC NULLS LAST, id DESC
),
reviewish AS (
  SELECT ts.span_id, ts.interaction_id, ts.span_index
  FROM target_spans ts
  JOIN latest_attr la ON la.span_id = ts.span_id
  WHERE la.decision IN ('review', 'none') OR la.applied_project_id IS NULL
),
claim_counts AS (
  SELECT
    source_span_id AS span_id,
    count(*) AS claim_rows
  FROM journal_claims
  WHERE active IS TRUE AND source_span_id IS NOT NULL
  GROUP BY source_span_id
)
SELECT
  (SELECT count(*) FROM reviewish) AS reviewish_spans,
  count(*) FILTER (WHERE cc.claim_rows IS NOT NULL) AS contaminated_spans,
  coalesce(sum(cc.claim_rows), 0) AS contamination_claim_rows
FROM reviewish r
LEFT JOIN claim_counts cc ON cc.span_id = r.span_id;
```

### D.6 Write the Report (Phase 5)

Use the GT Run Report v1 template structure. The report must include:

1. **Metadata**: both run_ids, timestamps, pipeline versions, seed script commit SHA
2. **Inputs**: manifest path, row counts, seed fact counts
3. **Baseline headline metrics** (Section A.2 values)
4. **Post-seed headline metrics** (same metrics)
5. **Delta table** (Section D.5 Step 2)
6. **Sentinel check results** (CHECK-1 through CHECK-6, each PASS/FAIL with evidence)
7. **Per-span decision changes** (summary: N upgraded, N downgraded, N stable, N regressed)
8. **Bucket-stratified metrics** (for each `bucket_tag` in manifest)
9. **Contamination report** (J0 contamination query output)
10. **Failure analysis** (top failures from post-seed run, with root cause notes)
11. **Recommendation**: SHIP / ITERATE / REVERT based on Section C criteria

Save to: `artifacts/gt/runs/moss_pilot_comparison_<UTC>/report.md`

---

## E) Manifest Template (Moss Pilot)

Filename: `artifacts/gt/manifests/gt_manifest_moss_pilot_v0.csv`

```csv
interaction_id,span_index,expected_project,expected_decision,anchor_quote,bucket_tags,notes,labeled_by,labeled_at_utc
```

**Required sentinel rows (known problem cases):**

```csv
cll_06E0P6KYB5V7S5VYQA8ZTRQM4W,0,hurley,assign,"Hancock County",bucket:moss_pilot;bucket:misattribution;bucket:sentinel,"KNOWN MISATTRIB: Pipeline says Moss; GT is Hurley. Hancock County location leak.",CHAD,2026-02-16T00:00:00Z
cll_06E09H1BF9R1VAGJ6ZGBSRY3E8,0,winship,assign,"Chris Gaugler roofing",bucket:moss_pilot;bucket:misattribution;bucket:sentinel,"KNOWN MISATTRIB: Pipeline says Moss@0.75; GT is Winship. Phase-incongruent.",CHAD,2026-02-16T00:00:00Z
```

**Population strategy:** All 32 Moss interactions, all non-superseded spans within each. Every span gets a GT label (project or `none`). Tag with applicable bucket tags.

---

## F) Environment Variables and Feature Flags

| Variable | Required Value | Purpose |
|----------|---------------|---------|
| `SUPABASE_URL` | `https://rjhdwidddtfetbwqolof.supabase.co` | Database access |
| `SUPABASE_SERVICE_ROLE_KEY` | (from credentials.env) | Service role auth |
| `EDGE_SHARED_SECRET` | (from credentials.env) | admin-reseed auth |
| `WORLD_MODEL_FACTS_ENABLED` | `true` (on ai-router Edge Function) | Feature flag to enable fact retrieval |
| `DATABASE_URL` | (from load-env.sh) | Direct psql access for proof queries |

---

## G) Appendix: Existing Tooling Reference

| Script | Path | Purpose |
|--------|------|---------|
| GT Eval Harness | `scripts/gt_evalharness_self_score_v1.py` | Manifest-based evaluation runner (reseed + score) |
| GT Registry Update | `scripts/gt_registry_update_from_manifest_v1.py` | Append GT labels to persistent registry |
| GT Registry Find | `scripts/gt_registry_find_v1.py` | Search GT registry by interaction or content |
| GT Fresh Picks | `scripts/gt_pick_fresh_review_items_v1.py` | Find unlabeled review-queue spans |
| Moss Seed (provenance) | `scripts/backfills/moss_residence_seed_v0.sql` | Insert ~25 project_facts with evidence_event provenance |
| Moss Seed (legacy) | `scripts/sql/seeds/seed_project_facts_moss.sql` | Earlier seed draft (uses placeholder project_id) |
| P2 Eval Scorer | `scripts/p2-eval-scorer.sh` | Statistical A/B comparison framework |
| NOW-leakage check | `scripts/sql/proofs/project_facts_now_leakage_template.sql` | Verify KNOWN_AS_OF filtering |
| Provenance hygiene | `scripts/sql/proofs/project_facts_missing_provenance.sql` | Detect orphan facts |
| Fact window counts | `scripts/sql/proofs/project_facts_window_counts.sql` | Count facts by time window |

| Artifact | Path | Purpose |
|----------|------|---------|
| GT Registry | `artifacts/gt/registry/gt_registry_v1.jsonl` | Persistent GT label store |
| GT Manifests | `artifacts/gt/manifests/` | Per-run GT label CSVs |
| GT Run Outputs | `artifacts/gt/runs/` | Per-run results (rows.jsonl, summary.json, report.md) |
| Run Report Template | `artifacts/_local_salvage_20260216/gt_run_report_v1.md.untracked` | Report template with contamination metrics |

---

## H) Appendix: World Model Facts Integration Surface

The `world_model_facts.ts` module (in `supabase/functions/ai-router/`) provides:

1. **`filterProjectFactsForPrompt()`** — Filters facts by:
   - Excluding facts from the same `interaction_id` (same-call exclusion)
   - Excluding facts from the same `evidence_event_id`
   - Capping to `max_per_project` (default 20)

2. **`buildWorldModelFactsCandidateSummary()`** — Formats facts into LLM prompt context:
   - Shows up to 3 facts per candidate project
   - Format: `[fact_kind] as_of=YYYY-MM-DD observed=YYYY-MM-DD fact=<compact payload>`

3. **`applyWorldModelReferenceGuardrail()`** — Post-LLM guardrail:
   - Validates LLM's `world_model_references` against actual `project_facts`
   - Checks for `hasStrongFactAnchor` (address-like, specific features, serial numbers)
   - Checks for `factContradictsTranscript` (negation pattern matching)
   - Can downgrade `assign` to `review` with reason codes:
     - `world_model_fact_contradiction`
     - `world_model_fact_weak_only`

### Strong fact anchor tokens

The guardrail considers a fact "strong" if its `fact_kind` contains any of:
`address`, `alias`, `client`, `scope`, `material`, `finish`, `feature`, `model`, `serial`, `room`, `lot`, `unit`

For Moss, the seeded facts include kinds like `scope.site`, `scope.feature`, `scope.material`, `scope.contact`, and `scope.dimension` — all of which should qualify as strong anchors.

---

## I) Appendix: Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Seed script uses wrong `project_id` | Low | Critical | Verify UUID matches before COMMIT |
| `WORLD_MODEL_FACTS_ENABLED` not set on ai-router | Medium | Blocks eval | Check env before reseed run |
| Human-locked spans block reseed | Known | Medium | Exclude from comparison; note in report |
| Reseed rate-limiting / timeouts | Medium | Delays eval | Eval harness has 0.25s sleep between reseeds |
| Facts from wrong time window leak in | Low | High | CHECK-6 validates KNOWN_AS_OF |
| Concurrent pipeline writes during eval | Low | Medium | Run eval during low-traffic window |
