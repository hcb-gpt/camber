# WP-5: Attribution Accuracy Follow-Up Fix Plan v0

**Date:** 2026-02-15
**Author:** DEV-3 (consolidated from dev-1, dev-3, dev-4, data-1)
**Status:** Proposed
**Baseline:** 50.0% accuracy (43/86 spans correct, pre-world-model)

---

## 1. Error Budget Summary

| Error Category | Spans | % of Errors (43) | Root Cause |
|---|---|---|---|
| Sittler staff-name leak | 16 | 37.2% | Staff name matched to client projects |
| Missing contact anchoring | 17 | 39.5% | No contact-project link to narrow candidates |
| Sub-misattribution | 10 | 23.3% | Correct contact, wrong project chosen |

**Total error spans: 43 / 86 = 50.0% error rate.**

---

## 2. Consolidated Fixes (Priority Order)

### Fix 1: Sittler Blocklist Activation (21 spans)

**Source:** dev-1 (blocklist vs closed-project filter), dev-4 (exposure quantification)

**Problem:** "Sittler Residence" appears in three variants (Madison, Bishop, Athens). Zack Sittler is HCB staff (the builder), not a client. The pipeline matches his name to Sittler Residence projects, producing 62 phantom attributions in `interactions` and 21 wrong span attributions in the GT set.

**Why closed-project filter is insufficient:** The closed-project hard filter (merged on `feat/closed-project-hard-filter`) removes candidates with status not in `{active, warranty, estimating}`. This catches some Sittler variants but NOT all -- if any Sittler Residence project has an eligible status, it still appears as a candidate. The blocklist is the correct mechanism because it targets specific projects regardless of status.

**Fix:** Populate `project_attribution_blocklist` (migration `20260126184038`) with all three Sittler Residence project IDs:
```sql
INSERT INTO project_attribution_blocklist (project_id, active, block_mode, reason)
SELECT id, true, 'hard_block', 'Staff name leak: Zack Sittler is HCB builder, not client'
FROM projects
WHERE project_name ILIKE '%sittler%';
```

**Verification:** ai-router already enforces blocklist post-inference (index.ts lines 1284-1303). No code change needed -- data-only fix.

**Expected impact:** +21 spans corrected (16 Sittler-leak category + 5 Sittler contamination in sub-misattribution where Sittler was a competing candidate). This is the single highest-leverage fix.

**Owner:** DATA

---

### Fix 2: Contact-Project Seed Corrections (7-10 spans)

**Source:** dev-3 (sub-misattribution root cause analysis), data-1 (contact fanout quality report)

**Problem:** `project_contacts` has over-broad `data_inferred` rows linking subcontractors to ALL projects instead of their actual projects. Examples:
- Brian Dove: 12 project_contacts rows (GT: Woodbery framing only) -- **highest leverage sub** per dev-4
- Malcolm Hetzer: 12 rows (GT: Winship electrical)
- Flynt Treadaway: 12 rows (GT: Winship + Woodbery)

When every sub maps to every project, contact-based attribution narrowing is defeated. The `v_contact_project_affinity` view has better signal (e.g., Malcolm Hetzer 57% Winship) but `project_contacts` over-broad rows dilute it.

**Fix (two-part):**

**Part A -- Prune over-broad rows:** Delete `source='data_inferred'` rows from `project_contacts` for the top multi-project subs where GT is known:
```sql
-- Brian Dove: keep only Woodbery projects
DELETE FROM project_contacts
WHERE contact_id = (SELECT id FROM contacts WHERE full_name ILIKE '%brian dove%')
  AND source = 'data_inferred'
  AND project_id NOT IN (SELECT id FROM projects WHERE project_name ILIKE '%woodbery%');

-- Malcolm Hetzer: keep only Winship
DELETE FROM project_contacts
WHERE contact_id = (SELECT id FROM contacts WHERE full_name ILIKE '%malcolm hetzer%')
  AND source = 'data_inferred'
  AND project_id NOT IN (SELECT id FROM projects WHERE project_name ILIKE '%winship%');
```

**Part B -- Seed high-confidence associations:** Insert `source='chad_directive'` rows for GT-confirmed associations (following Ron C Persall pattern which is already correctly anchored).

**Expected impact:** +7 spans (contact anchoring errors where the sub's actual project is known). Could reach +10 if affinity view picks up improved signal.

**Owner:** DATA (with GT confirmation from CHAD)

---

### Fix 3: Alias and Nickname Mapping (2-3 spans)

**Source:** dev-3 (sub-misattribution span analysis)

**Problem:** Callers use colloquial names that don't match project records:
- "Lou's house" / "Lou's place" -> should resolve to Winship Residence (Lou Winship is the client)
- "the Hurley job" vs "Hurley Residence" (less problematic, usually matches)

World model facts (WP-1) partially address this if `alias` facts are seeded. But the current 70 facts may not cover all nickname patterns.

**Fix:** Seed `project_facts` with alias-type facts for known colloquial references:
```sql
INSERT INTO project_facts (project_id, fact_kind, fact_key, fact_value, source, confidence)
VALUES
  ((SELECT id FROM projects WHERE project_name ILIKE '%winship%'), 'alias', 'client_nickname', 'Lou''s house', 'chad_directive', 1.0),
  ((SELECT id FROM projects WHERE project_name ILIKE '%winship%'), 'alias', 'client_nickname', 'Lou''s place', 'chad_directive', 1.0);
```

The world model guardrail (`applyWorldModelReferenceGuardrail()` in world_model_facts.ts line 276) already checks for strong anchor matches including aliases. Adding these facts wires the nicknames into the prompt.

**Expected impact:** +2 spans directly. Could help with future unseen nickname references.

**Owner:** DATA

---

### Fix 4: Phone Capture Gap Recovery (5-8 spans, indirect)

**Source:** data-1 (phone_capture_gap_fix.md)

**Problem:** ~33% of calls (62 of 72 phoneless rows) lack `contact_phone` data even though a valid US 10-digit number exists in `raw_snapshot_json`. Without phone, contact lookup fails, and contact-based attribution narrowing is unavailable.

**Fix (3-layer extraction, per data-1's design):**
1. **Layer 1:** Extract from structured JSON fields (`caller.phoneNumber`, `from`, `phoneNumber`)
2. **Layer 2:** Regex scan of full `raw_snapshot_json` for US 10-digit patterns
3. **Layer 3:** Transcript speaker labels (requires CHAD gate)

Layers 1-2 are ready to execute. Layer 3 needs CHAD approval.

**Expected impact:** Indirect -- recovering phone enables contact lookup, which enables fanout-based narrowing. Estimated +5-8 spans that currently fail contact resolution because of missing phone.

**Owner:** DATA (Layers 1-2), CHAD gate (Layer 3)

---

### Fix 5: Phase-Incongruent Attribution Guard (1-2 spans)

**Source:** dev-3 (sub-misattribution analysis)

**Problem:** Two spans attributed to projects in wrong construction phase. Example: a framing discussion attributed to a project in finish phase, when the caller's other project is actually in framing.

**Fix:** Add construction phase as a world model fact and use it as a soft signal in the prompt:
```sql
INSERT INTO project_facts (project_id, fact_kind, fact_key, fact_value, source, confidence)
SELECT id, 'scope', 'current_phase', 'framing', 'chad_directive', 0.9
FROM projects WHERE project_name ILIKE '%woodbery barns%';
```

The ai-router prompt already includes world model facts per candidate. Phase facts would appear alongside existing scope/material facts, giving the LLM context to prefer phase-congruent attributions.

**Expected impact:** +1-2 spans. Low volume but prevents a class of error.

**Owner:** DATA

---

## 3. Impact Summary

| Fix | Spans Fixed (est.) | Cumulative Accuracy | Effort |
|---|---|---|---|
| Baseline (current) | 43/86 correct | 50.0% | -- |
| Fix 1: Sittler blocklist | +21 | 74.4% (64/86) | Low (data-only) |
| Fix 2: Contact seeds | +7 | 82.6% (71/86) | Medium (needs GT) |
| Fix 3: Alias mapping | +2 | 84.9% (73/86) | Low (data-only) |
| Fix 4: Phone recovery | +5 | 90.7% (78/86) | Medium (migration) |
| Fix 5: Phase guard | +1 | 91.9% (79/86) | Low (data-only) |

**Projected ceiling: ~92% accuracy** (79/86 spans) with all five fixes applied.

Note: Estimates assume no overlap between fixes. Actual impact may differ if some spans benefit from multiple fixes simultaneously (double-counting) or if fixes interact unexpectedly.

---

## 4. Execution Order

1. **Sittler blocklist** (Fix 1) -- highest leverage, zero code changes, data-only
2. **Contact seed corrections** (Fix 2) -- requires GT confirmation for each sub
3. **Alias mapping** (Fix 3) -- quick data insert, no code changes
4. **Run WP-4 GT eval** after fixes 1-3 to measure actual vs projected
5. **Phone recovery** (Fix 4) -- larger migration, indirect impact
6. **Phase guard** (Fix 5) -- smallest impact, do last

---

## 5. Measurement Protocol

After each fix batch, run GT eval:
```bash
python3 /Users/chadbarlow/gh/hcb-gpt/camber/scripts/gt_batch_runner.py \
  --input /Users/chadbarlow/gh/hcb-gpt/camber/artifacts/gt/batches/gt_batch_v1_full.csv \
  --mode shadow \
  --baseline /Users/chadbarlow/gh/hcb-gpt/camber/proofs/gt/runs/<baseline_run>/results.csv
```

Report both:
- **86-span subset** accuracy (apples-to-apples with 50% baseline)
- **146-span full registry** accuracy (comprehensive)

---

## 6. Cross-References

| Document | Author | Key Finding |
|---|---|---|
| `docs/attribution-accuracy-report.md` | STRAT | 50% baseline, error categorization |
| `docs/contact_fanout_data_quality_v0.md` | DATA-1 | 74% phone anchoring, Sittler contamination, over-broad project_contacts |
| `docs/identity/phone_capture_gap_fix.md` | DATA/DEV-1 | 33% phoneless, 3-layer extraction design |
| `proofs/gt/inputs/2026-02-15/GT_LABELING.csv` | STRAT | Per-span GT labels with error annotations |
| `migrations/20260126184038_create_project_attribution_blocklist.sql` | DEV | Blocklist table DDL |

---

*This plan establishes the post-world-model accuracy improvement roadmap. Execute fixes 1-3, re-evaluate, then proceed to fixes 4-5.*
