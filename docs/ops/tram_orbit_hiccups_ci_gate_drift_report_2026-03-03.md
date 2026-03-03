# TRAM/Orbit Hiccups + CI Gate Drift Report (2026-03-03)

Scope:
- Validate why `invariant-gates` was drifting/skipping.
- Propose stale-claimed receipt takeover policy and operator tooling.
- Capture PAT/status-check access recommendation.

## CI Gate Behavior (Before vs After)

Before:
- `.github/workflows/deno-ci.yml` used `contains(github.event.pull_request.changed_files, 'path/')`.
- `github.event.pull_request.changed_files` is numeric count, not a changed-path list.
- Result: `invariant-gates` condition evaluated false on most PRs and silently skipped intended checks.

After:
- Workflow now runs on PR/manual trigger and computes path scope with `dorny/paths-filter@v3`.
- `invariant-gates` executes when files under `supabase/functions/**`, `supabase/migrations/**`, `scripts/**`, or `.camber/**` change.
- When out-of-scope, job logs an explicit skip reason rather than disappearing due invalid condition logic.

## Stale-Claimed Actionable Receipts: Policy

Takeover policy:
- Treat claims as stale when `claim_is_stale=true` or claimer last-seen exceeds 30 minutes.
- Require `takeover_rationale` on forced takeovers to keep an audit trail.
- Prefer reclaiming oldest high-priority stale items first to reduce queue-noise pressure.

Operator/tooling recommendations:
- Use `tram_work_items_actionable(to=DEV|DATA|STRAT, state=open)` and sort on `claim_is_stale`.
- Claim stale items via `tram_claim_work(..., takeover_rationale=...)`.
- Run periodic orphan cleanup with `tram_rehome_orphaned_for_session` for dead `for_session` targets.
- Keep a dashboard metric: `fresh_unclaimed_count` vs `stale_claimed_count` to avoid false “queue full” alarms.

## PAT + Status Check Access Recommendation

Issue:
- Some tokens cannot read full status rollups (especially GraphQL-dependent views).

Recommendation:
- Prefer `gh pr checks`/Checks API for gate decisions in automation.
- Standardize token scopes for CI bot users to include repository checks-read coverage.
- Keep fallback parsing path that does not rely on GraphQL `statusCheckRollup` when scope is limited.
