# Redline thread wave-2 perf probe (2026-02-27)

## Scope
- Endpoint: `redline-thread`
- Contact: `b0acfc66-7aef-4b6b-8754-d38cebc4df34`
- Runs per endpoint: `15`
- Baseline deploy: `v35` (`redline-thread_v2.0.2`)
- Final deploy in this wave: `redline-thread_v2.0.4`

## Code deltas in wave-2
- Initial timeline fetches run in parallel (`interactions` + `sms_messages`).
- Initial payload narrowed to timeline fields; call summary and sms content fetched only for paged rows.
- `calls_raw`, `conversation_spans`, and `journal_claims` are fetched in parallel.
- Count mode changed from `exact` to `planned` for initial scans.
- Default `THREAD_SCAN_MIN_ITEMS` lowered from `200` to `100`.

## Probe results (thread_first_contact)
- Before: p50 `1.118453s`, p95 `1.493467s`
- Final: p50 `0.959597s`, p95 `1.073645s`
- Delta: p50 `-0.158856s`, p95 `-0.419822s`

## Acceptance status
- JSON contract: PASS (`contract_ok_all=true`)
- Gate `p95 <= 1.0s`: NOT YET (current p95 `1.073645s`)

## Next concrete change
- Add targeted DB indexes for remaining hot lookups:
  - `journal_claims(call_id)`
  - `claim_grades(claim_id)`
  - (if missing) composite index supporting inbound-existence lookup on `sms_messages(contact_phone, sent_at desc, direction)`
- Re-run the same 15-run probe on the same contact after index rollout.
