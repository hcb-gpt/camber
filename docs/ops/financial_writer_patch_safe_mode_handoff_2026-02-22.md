# Financial Writer Patch Safe-Mode Handoff (2026-02-22)

## Scope
Patch the scheduler writer path so `scheduler_items.financial_json` always includes standardized numeric keys:

- `total_committed`
- `total_invoiced`
- `total_pending`
- `largest_single_item`

Patch artifact:

- `supabase/migrations/20260222064600_patch_scheduler_financial_writer.sql`

## Why This Matters
Current production probe shows financial payloads exist but no parseable amount keys:

- `rows_financial_json = 60`
- `rows_with_any_amount = 0`

This blocks `v_financial_exposure` from reporting meaningful money-at-risk values.

## What The Patch Does
1. Adds `_safe_amount(text)` helper for robust numeric parsing.
2. Adds `normalize_scheduler_item_financial(item, interaction_financial, existing_financial)`:
   - preserves existing `financial_json` object keys when present,
   - derives canonical numeric keys from item/interaction/existing variants,
   - keeps no-financial-context rows as `NULL` (does not fabricate context),
   - annotates normalized rows with `normalized_by=materialize_scheduler_items_v2`.
3. Replaces `public.materialize_scheduler_items()` writer behavior to populate `scheduler_items.financial_json`.
4. Backfills existing rows with missing canonical keys using existing `payload` + interaction context.

## Migration Conflict Map (linked project snapshot)
Source command:

```bash
supabase migration list --linked
```

Notable local-only versions currently pending in linked state:

- `20260131154730`
- `20260209011017`
- `20260216050000`
- `20260216090000`
- `20260216090100`
- `20260216095000`
- `20260216100000`
- `20260216110000`
- `20260216230557`
- `20260216235900`
- `20260217000000`
- `20260219000000`
- `20260219100000`
- `20260222025200`
- `20260222051200`
- `20260222063100`
- `20260222063700`
- `20260222064500` (this patch)
- `20260222065500`
- `20260222235900`

No remote-only entries detected in this snapshot.

## Apply Playbook (Owner Lane)
Run in an isolated migration owner lane with no competing apply jobs.

1. Preflight snapshot:
```bash
supabase migration list --linked > .scratch/apply_owner_migration_list_pre.txt
```

2. Confirm patch file is present at:
```bash
ls supabase/migrations/20260222064600_patch_scheduler_financial_writer.sql
```

3. Dry run (shows ordered pending set + catches syntax/order faults):
```bash
supabase db push --linked --dry-run --include-all
```

4. Controlled apply:
```bash
supabase db push --linked --include-all
```

5. Post-apply verification (must prove delta):
```sql
with parsed as (
  select
    id,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_committed',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_committed}',''),'[^0-9.-]','','g'),'')::numeric
    ) as committed,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_invoiced',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_invoiced}',''),'[^0-9.-]','','g'),'')::numeric
    ) as invoiced,
    coalesce(
      nullif(regexp_replace(coalesce(financial_json->>'total_pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json->>'amount_pending',''),'[^0-9.-]','','g'),'')::numeric,
      nullif(regexp_replace(coalesce(financial_json #>> '{financial,total_pending}',''),'[^0-9.-]','','g'),'')::numeric
    ) as pending
  from scheduler_items
  where financial_json is not null
)
select
  count(*) as rows_financial_json,
  count(*) filter (where committed is not null) as rows_with_committed,
  count(*) filter (where invoiced is not null) as rows_with_invoiced,
  count(*) filter (where pending is not null) as rows_with_pending,
  count(*) filter (where committed is not null or invoiced is not null or pending is not null) as rows_with_any_amount
from parsed;
```

6. Expected outcome:
- Before: `rows_with_any_amount = 0`
- After: `rows_with_any_amount > 0` (where derivable from payload context)

7. Publish completion with:
- `MIGRATION: 20260222064600_patch_scheduler_financial_writer`
- verification query output
- before/after counts
- apply logs pointer

