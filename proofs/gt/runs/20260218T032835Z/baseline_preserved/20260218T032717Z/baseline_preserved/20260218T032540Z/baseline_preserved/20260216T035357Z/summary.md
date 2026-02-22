# GT Batch Runner Report (v1)

- Run ID: `20260216T035357Z`
- Mode: `reseed`
- Reseed mode: `reseed_and_close_loop`
- Input: `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/inputs/2026-02-16/gt_batch_v1_woodbery_subset.csv`
- Output dir: `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z`

## Metrics
- accuracy: `0.5405` (20/37)
- review_rate: `0.5405` (20/37)
- homeowner_override_fail_count: `1`
- staff_leak_count: `5`
- multi_project_span_count: `0`
- missing_char_offsets_count: `0`
- trigger_fail_count: `19`
- failures_count: `17`

## Artifacts
- `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z/summary.md`
- `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z/metrics.json`
- `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z/results.csv`
- `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z/failures.csv`
- `/Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs/20260216T035357Z/trigger_results.csv`

## Repro
```bash
python3 scripts/gt_batch_runner.py --input /Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/inputs/2026-02-16/gt_batch_v1_woodbery_subset.csv --mode reseed --out-root /Users/chadbarlow/gh/hcb-gpt/camber-calls/proofs/gt/runs
```
