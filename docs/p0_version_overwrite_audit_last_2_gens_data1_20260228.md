# P0 Version-Overwrite Audit (DATA-1)

Date: 2026-02-28
Window: last 7 days + last 2 accepted deploy generations per function
Receipt: dispatch__p0_version_overwrite_audit_last_2_gens_takeover__data1__20260228

## Scope and proof source
- Deploy generations source: `public.edge_deploy_receipts`
- Runtime overwrite/regression probes:
  - `public.evidence_events` (`source_id`, `source_run_id`)
  - `public.journal_claims` (`call_id`, `run_id`)
  - `public.journal_open_loops` (`call_id`, `run_id`)
  - `public.calls_raw` (`interaction_id`, `pipeline_version`)
  - `public.event_audit` (`interaction_id`, `pipeline_version`, `source_run_id`)
- SQL proof pack:
  - `scripts/sql/p0_version_overwrite_audit_last_2_gens_proof_20260228.sql`

## Last 2 deploy generations (accepted)
- `redline-thread`
  - gen1: `98f321695158ab5104a60265a4f7e01fe338f30c` at 2026-02-28 01:21:57 UTC
  - gen2: `cf3701b589f1bba1f471c71a1ad248a3816289d7` at 2026-02-28 01:17:17 UTC
- `segment-call`
  - gen1: `b4d0cd330c802847457b5f3633e298477286b7f8` at 2026-02-23 02:28:27 UTC
  - gen2: `625e557b78a2eb45588465c24b6e59bbb5e3fb98` at 2026-02-23 02:28:02 UTC

## Findings
1. interaction IDs with >1 distinct run_id
- Count: `156` interaction IDs
- Contributing rows: `3886`
- Pattern: high replay/reprocessing fanout, concentrated in journal/evidence paths.

2. multi-write keys inside 1 hour (possible overwrite pressure)
- Count: `20` logical keys
- Contributing rows: `55`
- Concentration: all top samples were in `event_audit` keyed by `interaction_id`.

3. version regressions
- Accepted deploy regressions by commit timestamp: `0`
- Runtime pipeline_version regression events: `44` across `42` interaction IDs
- Dominant transition: `v4.3.x -> v1.0.2` in `event_audit` rows (possible fallback or mixed-version writer path).

## Blast-radius read
- Deploy control-plane looked healthy (no accepted rollback-by-time regressions).
- Data-plane still showed mixed run/version writes in the same interaction timelines.
- Risk surface is primarily runtime writer consistency and replay ordering, not the deploy acceptance gate itself.

## Top sample pointers
- Multi-run_id examples include:
  - `cll_06DJFFS345X7NF3FE8Y7KTMB4G` (16 distinct run IDs)
  - `cll_06DSN33ZRHZE1EQ5DETW4EQ4H0` (15 distinct run IDs)
  - `cll_06DJHCFH99TQQ7KXXDC5BKXKAW` (15 distinct run IDs)
- Multi-write<1h examples include:
  - `cll_06EA0WZCR9WVKA41DHMYTRYAKR`
  - `cll_06EA0X5Q89SSVFQ6YHYPTZBTAM`
  - `cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0`
- Runtime version-regression examples include:
  - `cll_SMOKE_TEST` (`v4.3.9 -> v1.0.2`)
  - `cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0` (`v4.3.9 -> v1.0.2`)

## Recommended mitigations
1. Enforce immutable append-only event ledger at ingestion boundary
- Avoid in-place mutation on interaction lifecycle records used for truth decisions.

2. Require monotonic version guards in runtime writes
- Reject writes when `incoming_version < stored_version` for guarded tables.

3. Adopt strict idempotency keys per writer stage
- Key shape: `(interaction_id, stage, run_id, generation)`; reject duplicates and out-of-order backfills without explicit override.

4. Gate replay/backfill pathways with explicit mode flags
- Separate `replay` and `live` modes; prevent replay writes from downgrading live-version state.

5. Add automated regression canary query in pipeline health loop
- Run Q4-style regression detector each cycle and emit critical alert on non-zero.

6. Persist overwrite-attempt receipts
- Any blocked or rejected overwrite should emit durable receipt with interaction pointer and reason.
