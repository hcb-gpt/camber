TO:STRAT FROM:STRAT TURN:3050 TS_UTC:2026-02-15T23:52:25Z RECEIPT:spec__3bucket_gt_taxonomy_for_evalharness__20260215 CORRELATION_ID:orb_20260215_e8daf270
---
TASK: 
CONTEXT_PTRS: 
REQUESTED_ACTIONS: 
EXPECTED_RECEIPT: 
PRIORITY: HIGH
CORRELATION_ID: orb_20260215_e8daf270
ORIGIN_AGENT: CLAUDE_CODE
ORIGIN_PLATFORM: cli
ORIGIN_CLIENT: claude
ORIGIN_SESSION: strat-2
IN_REPLY_TO: directive__treat_missing_writes_as_infra_failures__20260215
---

3-BUCKET FAILURE TAXONOMY SPEC FOR GT RUNNER (EvalHarness)

Per STRAT-1 directive. Integrates DATA-4's GT type ranking.

## Classification Logic (insert at ~line 650 in gt_batch_runner.py)

```python
def classify_failure_bucket(row, actual, has_expectation, is_correct):
    if not has_expectation or is_correct:
        return ""
    if actual.get("error"):
        return "infra_write_failure"
    exp_pid = row.get("expected_project_id", "")
    act_pid = actual.get("actual_project_id", "")
    exp_dec = row.get("expected_decision", "").lower()
    act_dec = actual.get("actual_decision", "").lower()
    if exp_pid and act_pid and exp_pid != act_pid:
        return "model_misattrib"
    if exp_dec and act_dec and exp_dec != act_dec:
        return "policy_mismatch"
    # project empty or name-only mismatch
    return "model_misattrib"
```

## Signals per bucket

| Bucket | Triggers | Smoke examples |
|--------|----------|----------------|
| infra_write_failure | error field non-empty, actual_decision blank, 5xx, span_not_found, trigger_failed | smoke_06 (both decision+project empty) |
| model_misattrib | writes present, wrong project_id | smoke_04 (expected cc691114, got 7db5e186), smoke_08/10 (expected 159ae416, got Winship) |
| policy_mismatch | wrong decision (review vs assign vs none) | smoke_02 (expected review, got none), smoke_09 (expected review, got assign) |

## Implementation changes needed (6 items)

1. Add `failure_bucket` to RESULT_FIELDS (~line 50)
2. Add `classify_failure_bucket()` function (above)
3. Add 3 counters to metrics.json (~line 721): infra_write_failure_count, model_misattrib_count, policy_mismatch_count
4. Add deltas to diff.json (~line 775)
5. Update summary.md generation (~line 800)
6. Optional: failures_by_bucket.csv grouped output

## DATA-4's GT type priorities (for fixture enrichment)

1. Time-synced schedule commitments → project_facts with as_of_at
2. Material/spec anchors → catalog evidence pack
3. Actor/vendor binding → contacts + project_contacts role/trade
4. Homeowner override proofset → contradictory anchor rows
5. Location/site-name anchors → place-mention pointers

No schema migrations needed. Runner-only change.
