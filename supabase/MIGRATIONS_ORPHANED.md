# Migrations Orphaned (Do Not Apply Blindly)

This repo contains a `supabase/migrations_orphaned/` directory.

## What It Is

`supabase/migrations_orphaned/` is a quarantine area for migration SQL files that:

- exist locally in git, but
- are **not** safe to apply to the linked Supabase project via `supabase db push`
  without explicitly reviewing out-of-order history and remote state.

These files are **not** read by the Supabase CLI migration runner (it only reads
`supabase/migrations/`).

## Why It Exists

At times, local branches accumulate migration files whose versions are earlier
than the latest version recorded in the remote `supabase_migrations.schema_migrations`
table. In that state, the Supabase CLI will refuse a normal `db push` and will
require `--include-all`, which can accidentally apply a large number of
historical migrations to production.

We quarantine those files to unblock safe forward migration pushes.

## Rules

- Do not run `supabase db push --include-all` against prod without STRAT approval
  and a written plan.
- If a file in `migrations_orphaned/` is needed in prod, promote it intentionally:
  move it into `supabase/migrations/` with a **new** timestamped version and
  apply with a guarded claim.

