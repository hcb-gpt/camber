# Migration Version Collision Reconcile (2026-02-22)

Observed blocker from apply-owner run:

- `supabase db push --linked --include-all` blocked on duplicate migration history key (`version=20260131154730` already exists).

## Confirmed duplicate local version collisions

- `20260131154730_create_score_interaction_function.sql`
- `20260131154730_create_score_interaction_function_v2.sql`

- `20260209011017_create_get_project_state_snapshot_rpc.sql`
- `20260209011017_drop_review_queue_interaction_id_unique.sql`

- `20260216050000_create_labeling_results_table.sql`
- `20260216050000_wp_b_caller_phone_resolution.sql`

## Recommended safe reconcile path (owner lane only)

1. Snapshot current migration state:
```bash
supabase migration list --linked > .temp/migration_list_pre_reconcile.txt
```

2. Keep already-applied canonical versions as-is, and rename local duplicate files that share the same version prefix to unique later timestamps (preserving lexical order).

3. Re-run dry-run:
```bash
supabase db push --linked --dry-run --include-all
```

4. If the same duplicate key still appears for an already applied version, repair migration history only with explicit owner confirmation:
```bash
supabase migration repair --status applied <version>
```
or
```bash
supabase migration repair --status reverted <version>
```
Use `repair` only after verifying the SQL object state in DB matches intended status.

5. Apply:
```bash
supabase db push --linked --include-all
```

6. Post-apply proof:
- run `scripts/query.sh --file scripts/proof_financial_writer_apply.sql`
- ensure `rows_with_any_amount > 0`

## Notes

- We already resolved one collision in this lane by renaming:
  - from `20260222064500_patch_scheduler_financial_writer.sql`
  - to `20260222064600_patch_scheduler_financial_writer.sql`
- Current blocker is older duplicate-version entries listed above.
