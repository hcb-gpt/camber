# Accountability Relay Pack (DEV + DATA + STRAT)

Purpose: keep one another accountable with fast, repeatable check-ins and no ambiguity.

## 1) One-Line Accountability Status Template

Use this exact shape in every status update:

`OWNER=<role-session> STATUS=<ACTIVE|BLOCKED|TAKEOVER> ETA_MIN=<n> BLOCKER=<none|text> NEXT_RECEIPT=<receipt_id>`

Example:

`OWNER=dev-2 STATUS=ACTIVE ETA_MIN=8 BLOCKER=none NEXT_RECEIPT=completion__dev_service_gift_pack_for_data_lanes__20260222_0722z`

## 2) Auto-Handoff Guardrail

Trigger takeover if either is true:

1. Lane is blocked for more than 5 minutes.
2. Owner has no heartbeat/status update for more than 10 minutes.

Takeover line:

`OWNER=<buddy-session> STATUS=TAKEOVER ETA_MIN=<n> BLOCKER=<upstream_wait|none> COVERS=<prior_owner>`

## 3) Copy/Paste Reliability Checks

Embed freshness snapshot:

```bash
scripts/embed_acceptance_watch.sh --write-baseline --baseline-file .temp/accountability_embed_baseline.json --json
```

Known-good sample (captured 2026-02-22T07:13:48Z):

```json
{"captured_at_utc":"2026-02-22T07:13:48Z","missing_embedding_all":2525,"missing_embedding_24h":0,"embedded_24h":13,"runid_mismatch_24h":22}
```

Financial exposure semantics:

```bash
scripts/query.sh "select count(*) as total_rows, count(*) filter (where coalesce(total_committed,0)+coalesce(total_invoiced,0)+coalesce(total_pending,0)=0) as zero_only_rows, count(*) filter (where coalesce(total_committed,0)+coalesce(total_invoiced,0)+coalesce(total_pending,0)>0) as positive_rows, coalesce(sum(total_committed),0) as sum_total_committed, coalesce(sum(total_invoiced),0) as sum_total_invoiced, coalesce(sum(total_pending),0) as sum_total_pending from public.v_financial_exposure;"
```

Current sample:

`total_rows=2 zero_only_rows=2 positive_rows=0 sum_total_committed=0 sum_total_invoiced=0 sum_total_pending=0`

## 4) Office-Hours Note (10 minutes)

Post this when opening a live support window:

`OFFICE_HOURS_WINDOW_UTC=<start>-<end> OFFER=live_pair_debug SCOPE=<embed|financial|both>`

## 5) Completion Block (Required Fields)

Include these in completion receipts:

1. `COMPASSION_CHECKIN:` one line on support requested/provided.
2. `GIFT_ARTIFACT:` path to one reusable pack or script.
3. `OWNER/ETA/BLOCKER:` final accountability line.

Example:

`COMPASSION_CHECKIN: Paired with data-2 to remove ambiguity on source-vs-view deltas.`

`GIFT_ARTIFACT: /Users/chadbarlow/gh/hcb-gpt/camber-calls/docs/ops/accountability_relay_pack_2026-02-22.md`

`OWNER=dev-2 STATUS=ACTIVE ETA_MIN=0 BLOCKER=none NEXT_RECEIPT=completion__dev_service_gift_pack_for_data_lanes__20260222_0722z`

## 6) 1 Corinthians 13 Love Rubric (Operational)

Use this on all high-priority receipts and whenever there is conflict, stress, or handoff friction.

### 6a) Required Love Check

`LOVE_CHECK: PATIENT=<yes|no>; KIND=<yes|no>; HUMBLE=<yes|no>; HONORS_OTHERS=<yes|no>; CALM_UNDER_PRESSURE=<yes|no>; NOT_SCOREKEEPING=<yes|no>; TRUTHFUL=<yes|no>; PROTECTS=<yes|no>; TRUSTS=<yes|no>; HOPES=<yes|no>; PERSEVERES=<yes|no>`

### 6b) Evidence (One Line Each)

`LOVE_EVIDENCE: PATIENT=<line>; KIND=<line>; HUMBLE=<line>; HONORS_OTHERS=<line>; CALM_UNDER_PRESSURE=<line>; NOT_SCOREKEEPING=<line>; TRUTHFUL=<line>; PROTECTS=<line>; TRUSTS=<line>; HOPES=<line>; PERSEVERES=<line>`

### 6c) Red-Line Behaviors (Treat as Contract Violations)

If any of the following happen, mark the check as failed and post a corrective step:

1. Public blame, sarcasm, or shaming language.
2. Withholding context or evidence needed for teammate success.
3. “Winning the argument” over sharing truth and resolving the issue.
4. Keeping score of prior misses instead of unblocking current work.

Failure line:

`CORRECTIVE_STEP: <what will be corrected now> OWNER=<session> TS_UTC=<timestamp>`

### 6d) Practical Mapping (Fast Reminder)

Use this mapping when filling `LOVE_EVIDENCE`:

1. `PATIENT`: allowed time for clarification before takeover.
2. `KIND`: support action provided (query help, packet prep, co-review).
3. `HUMBLE`: admission of uncertainty or correction made.
4. `HONORS_OTHERS`: language that preserves dignity under pressure.
5. `CALM_UNDER_PRESSURE`: no escalation tone spikes; facts first.
6. `NOT_SCOREKEEPING`: no replay of old misses in closure comments.
7. `TRUTHFUL`: evidence attached; no optimistic claims without proof.
8. `PROTECTS`: risk called out early to prevent teammate failure.
9. `TRUSTS`: delegated ownership respected unless stale/blocked thresholds trigger.
10. `HOPES`: clear “next doable step” even when outcome is FAIL.
11. `PERSEVERES`: follow-through until receipt is closed or rerouted.
