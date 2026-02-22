# GT Batch Runner Report (v1)

- Run ID: `20260218T032717Z`
- Mode: `reseed`
- Reseed mode: `resegment_and_reroute`
- Input: `/Users/chadbarlow/gh/hcb-gpt/camber-calls/artifacts/gt/batches/gt_batch_v1_baseline86.csv`
- Output dir: `proofs/gt/runs/20260218T032717Z`

## Metrics
- accuracy: `0.0465` (4/86)
- review_rate: `0.5` (4/8)
- homeowner_override_fail_count: `0`
- staff_leak_count: `0`
- multi_project_span_count: `0`
- missing_char_offsets_count: `0`
- trigger_fail_count: `46`
- failures_count: `82`

## Diff vs Baseline
- baseline_metrics: `proofs/gt/runs/20260218T032717Z/baseline_preserved/20260218T032540Z/metrics.json`
- baseline_metrics_source: `proofs/gt/runs/20260218T032540Z/metrics.json`
- baseline_metrics_preserved: `proofs/gt/runs/20260218T032717Z/baseline_preserved/20260218T032540Z/metrics.json`
- delta_accuracy: `0.0`
- delta_review_rate: `0.0`
- delta_staff_leak_count: `0`
- delta_homeowner_override_fail_count: `0`
- delta_multi_project_span_count: `0`
- delta_missing_char_offsets_count: `0`

## Artifacts
- `proofs/gt/runs/20260218T032717Z/summary.md`
- `proofs/gt/runs/20260218T032717Z/metrics.json`
- `proofs/gt/runs/20260218T032717Z/results.csv`
- `proofs/gt/runs/20260218T032717Z/failures.csv`
- `proofs/gt/runs/20260218T032717Z/trigger_results.csv`
- `proofs/gt/runs/20260218T032717Z/diff.json`

## Repro
```bash
python3 scripts/gt_batch_runner.py --input /Users/chadbarlow/gh/hcb-gpt/camber-calls/artifacts/gt/batches/gt_batch_v1_baseline86.csv --mode reseed --out-root proofs/gt/runs
```
