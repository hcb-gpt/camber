# Consolidation Delta Probe v1 (2026-02-22)

## Purpose

Provide a fast, repeatable probe for the "consolidation no-delta" condition:
`journal-consolidate` returns success, but `module_claims` and `module_receipts`
remain unchanged.

## Script

- `scripts/consolidation_delta_probe.sh`

## Usage

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
./scripts/consolidation_delta_probe.sh --run-id <journal_run_uuid>
```

Read-only mode:

```bash
./scripts/consolidation_delta_probe.sh --run-id <journal_run_uuid> --no-invoke
```

JSON mode:

```bash
./scripts/consolidation_delta_probe.sh --run-id <journal_run_uuid> --json
```

## Output Contract

The probe prints:

- `run_id`, `run_status`, `project_id`, `call_id`
- `journal_runs.claims_extracted`
- `journal_claims_for_run`
- `module_claims` before/after + delta
- `module_receipts` before/after + delta
- `invoke_http_code` and `invoke_response`
- machine line: `CONSOLIDATION_DELTA_PROBE ...`

## Interpretation

- If `journal_claims_for_run > 0` and both module deltas are `0`, the lane is
  likely blocked downstream of consolidation execution.
- If invoke succeeds (`200`) but module deltas remain zero, check lineage and
  ownership for module sink writers.
- If invoke fails (`401/403`), escalate auth failure immediately per charter.

## Example Outcome Pattern

- run has claims (`journal_claims_for_run=3`)
- invoke returns success with `claims_processed=3`
- `module_claims_delta=0`
- `module_receipts_delta=0`

This is the canonical "consolidation executed, no module sink movement" signal.
