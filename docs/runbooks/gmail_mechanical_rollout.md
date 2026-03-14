# Mechanical Gmail Rollout

## Current rollout contract

- Reference mailbox profile set: `finance_zack_v1`
- Reference mailbox schedule row: `finance_zack_prod`
- Steady-state pipeline key: `finance_zack_prod`
- Rollout helper RPC: `public.fire_gmail_financial_pipeline_schedule(...)`
- Steady-state dispatcher RPC: `public.cron_fire_gmail_financial_pipeline_dispatcher()`

## Rollout sequence

### 1. Shadow

Run bounded dry-runs before any live writes:

```sql
select public.fire_gmail_financial_pipeline_schedule(
  'finance_zack_prod',
  true,
  180,
  'finance_zack_shadow_180d',
  'full'
);

select public.fire_gmail_financial_pipeline_schedule(
  'finance_zack_prod',
  true,
  365,
  'finance_zack_shadow_365d',
  'full'
);
```

Required gate:

- no auth failures
- no `mixed_mailbox_scope`
- no candidate upsert/update failures
- candidate rows created in `gmail_financial_candidates`
- review items visible in `v_gmail_financial_review_queue`

### 2. Manual guarded live

Enable live writes for the mailbox, but keep cron off:

```sql
update public.gmail_financial_pipeline_schedules
set write_enabled = true,
    cron_enabled = false,
    updated_at = now()
where schedule_slug = 'finance_zack_prod';
```

Run bounded live smoke, then bounded live backfill:

```sql
select public.fire_gmail_financial_pipeline_schedule(
  'finance_zack_prod',
  false,
  30,
  'finance_zack_live_30d',
  'full'
);

select public.fire_gmail_financial_pipeline_schedule(
  'finance_zack_prod',
  false,
  180,
  'finance_zack_live_180d',
  'full'
);
```

Optional 365d expansion:

```sql
select public.fire_gmail_financial_pipeline_schedule(
  'finance_zack_prod',
  false,
  365,
  'finance_zack_live_365d',
  'full'
);
```

### 3. Cron cutover

Only after the mailbox passes manual live gates:

```sql
update public.gmail_financial_pipeline_schedules
set cron_enabled = true,
    updated_at = now()
where schedule_slug = 'finance_zack_prod';
```

The dispatcher returns one result object per active cron-enabled schedule:

```sql
select public.cron_fire_gmail_financial_pipeline_dispatcher();
```

### 4. Rollback

Disable new schedule rows first. Re-enable legacy singleton cron separately if needed.

```sql
update public.gmail_financial_pipeline_schedules
set cron_enabled = false,
    write_enabled = false,
    updated_at = now()
where schedule_slug = 'finance_zack_prod';
```

## Adding another mailbox

Each mailbox needs:

1. one mailbox-specific `profile_set`
2. one schedule row in `gmail_financial_pipeline_schedules`
3. the same shadow -> manual live -> cron progression

Do not mix mailbox scopes inside one `profile_set`.

Recommended naming:

- `profile_set = finance_<mailbox_slug>_v1`
- `pipeline_key = finance_<mailbox_slug>_prod`
- `schedule_slug = finance_<mailbox_slug>_prod`

## Live status as of 2026-03-14

Applied in production:

- `20260314183000_add_mechanical_gmail_finance_workflow.sql`
- `20260314213000_add_gmail_finance_rollout_scheduler.sql`
- `20260314222500_fix_gmail_financial_review_queue_security_invoker.sql`
- `gmail-financial-pipeline` deployed with the staged workflow contract
- legacy singleton Gmail cron jobs disabled, but left present for rollback

Current live reference mailbox:

- mailbox: `zack@heartwoodcustombuilders.com`
- `profile_set = finance_zack_v1`
- `schedule_slug = finance_zack_prod`
- `cron_enabled = false`
- `write_enabled = false`

Completed shadow passes:

- `finance_zack_shadow_180d_r4`
- `finance_zack_shadow_365d_r4`
- `finance_zack_shadow_30d_r1`

Observed shadow results:

- `180d_r4`: `237` messages examined, `66` auto-extract, `145` review, `44` dry-run receipt inserts
- `365d_r4`: `249` messages examined, `66` auto-extract, `157` review, `44` dry-run receipt inserts
- `30d_r1`: `96` messages examined, `18` auto-extract, `52` review, `10` dry-run receipt inserts

What improved:

- broad retrieval is live from `gmail_query_profiles`
- all candidates are persisted in `gmail_financial_candidates`
- review routing is live via `v_gmail_financial_review_queue`
- obvious false positives like Picsart/GetFPV, Google Workspace invoice notices, and Calendly reminders no longer auto-extract
- internal `Heartwood Custom Builders` target matches no longer count as sufficient affinity
- weak single-name aliases like `Chris` no longer count as sufficient project affinity

Remaining blockers before live writes or cron cutover:

- missing input: additional mailbox list for the same-release wave beyond Zack
- classifier quota: repeated `gmail_finance_classifier_http_429` warnings still appear during shadow runs
- manual live is intentionally still off until the current review queue is sampled and accepted

Current recommendation:

- keep Zack on shadow-only
- do not enable `write_enabled` or `cron_enabled` yet
- add the remaining mailbox scopes only after the mailbox list is finalized
