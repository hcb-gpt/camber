# Edge Version Overwrite Audit + Prevention (DATA-1, 2026-02-28)

## Scope
- Receipt lane: `epic__edge_version_overwrite_audit_2gen_and_prevention__20260228`
- Queue extension: `queue_ext__version_overwrite_prevention_deploy_receipts_and_guards__20260228`

## Audit Method
1. Deployment-receipt inventory check:
   - No pre-existing public deploy receipt table/functions were found in DB schema.
2. Historical proxy audit:
   - Used local git history for critical edge function files as the only available pre-receipt evidence source.
3. Prevention implementation:
   - Added durable DB deploy receipts + guard + monitor + scheduled heartbeat.

## Historical Proxy Evidence (git history)
Critical function `redline-thread` (`supabase/functions/redline-thread/index.ts`):
- `ec0db294...` at `2026-02-27T20:03:38-05:00`
- `cf3701b5...` at `2026-02-27T20:17:17-05:00`
- `98f32169...` at `2026-02-27T20:21:57-05:00`

Critical function `segment-call` (`supabase/functions/segment-call/index.ts`):
- `8108c48e...` at `2026-02-22T21:24:56-05:00`
- `625e557b...` at `2026-02-22T21:28:02-05:00`
- `b4d0cd33...` at `2026-02-22T21:28:27-05:00`

Observation:
- Both functions show rapid successive changes (minutes/seconds apart), which raises overwrite/redeploy risk when deploy ordering is uncontrolled.

## Impact Window (inferred from available evidence)
- Without historical deploy receipts, exact live-deploy windows cannot be proven retroactively.
- Best available inferred risk windows are commit-time intervals above, especially:
  - `redline-thread` around `20:03 -> 20:22` local time (Feb 27)
  - `segment-call` around `21:24 -> 21:29` local time (Feb 22)

## Blast Radius Context (existing data quality evidence)
- From span generation audit (`scripts/sql/overwritten_generation_audit_20260228.sql`):
  - `conversation_spans` superseded: `1333 / 2851` (`46.76%`)
  - latest-generation rows already superseded: `170`
  - active non-latest anomaly: `1`
- This is not itself deploy evidence, but indicates real version-churn impact surfaces.

## Prevention Implemented (live)
Migration:
- `supabase/migrations/20260228062000_create_edge_deploy_receipts_and_guard.sql`
- `supabase/migrations/20260228062500_schedule_edge_deploy_guard_monitor.sql`

Objects:
- Table: `public.edge_deploy_receipts`
- Function: `public.record_edge_deploy_receipt(...)`
- Views:
  - `public.v_edge_deploy_guard_alerts`
  - `public.v_edge_deploy_guard_summary`
- Monitor function: `public.run_edge_deploy_guard_monitor(...)`
- Cron: `edge_deploy_guard_monitor_10m`

Guard behavior proven:
- Older-sha attempts blocked for both functions (`rejection_reason='older_sha_blocked'`).
- Rapid redeploy events detected for both functions.
- Monitor emits alert snapshot in `monitor_alerts` when anomalies present.

Proof pack:
- `scripts/sql/edge_deploy_guard_proof_20260228.sql`

## What Was Lost / Recovery Going Forward
- Past exact deploy order and runtime windows are not recoverable with high confidence because receipts were absent.
- Going forward, each deploy can be durably recorded and validated by guard logic before acceptance.

## Dependency / Handoff to DEV
- CI/CD (or deploy operator path) must call `record_edge_deploy_receipt(...)` on every edge deploy.
- If a deploy is blocked (`accepted=false`), deploy pipeline should fail unless explicit override is used.

