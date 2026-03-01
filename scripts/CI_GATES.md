# CI Gates — Migration Safety

Two gates protect the `supabase/migrations/` directory from multi-agent write
collisions and unintentional version overwrites.

---

## Gate 1: Migration Version Collision Check

**What it detects:** Duplicate migration timestamp prefixes. Supabase migrations
are ordered by their numeric prefix (e.g., `20260228161200`). If two files share
the same prefix, `supabase db push` applies them in undefined order, causing
non-deterministic schema state.

**Scripts (two variants, same purpose):**

| Script | Invocation |
|--------|-----------|
| `scripts/check_migration_version_collisions.sh` | `./scripts/check_migration_version_collisions.sh` |
| `scripts/check_duplicate_migration_versions.sh` | `./scripts/check_duplicate_migration_versions.sh [root_dir]` |

Both scan `supabase/migrations/*.sql`, extract the leading `_`-delimited
timestamp prefix from each filename, and exit non-zero when any prefix appears
more than once.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | No collisions — safe to proceed |
| 1 | Collisions found — must fix before merge/deploy |
| 2 | Migration directory not found (config error) |

**What a failure looks like:**

```
FAIL: duplicate migration version prefixes detected:
- version 20260228161000 has 2 files:
  - 20260228161000_create_foo.sql
  - 20260228161000_add_bar_column.sql
```

**How to fix:**

Rename one of the colliding files so its timestamp prefix is unique. Convention:
bump the last 2 digits by the smallest increment that resolves the collision.

```bash
# Example: rename to avoid collision at 20260228161000
mv supabase/migrations/20260228161000_add_bar_column.sql \
   supabase/migrations/20260228161200_add_bar_column.sql
```

Then re-run the checker to confirm:

```bash
./scripts/check_migration_version_collisions.sh
# Expected: PASS: no duplicate migration version prefixes found.
```

---

## Gate 2: Version Overwrite Audit SQL

**What it detects:** Unintentional overwrites of migration-managed objects
(views, functions, constraints) where a later generation silently replaces an
earlier one. This is a deeper check than filename collisions — it inspects the
*content* of recent migrations for semantic conflicts.

**4 Proof Classes (Q0–Q3B):**

| Class | Name | What it checks |
|-------|------|---------------|
| Q0 | **Timestamp collision** | Same numeric prefix on two or more `.sql` files (overlaps with Gate 1, included for completeness in the SQL audit) |
| Q1 | **View overwrite** | Two migrations in the last 2 generations that `CREATE OR REPLACE` the same view — the second silently replaces the first |
| Q2 | **Function overwrite** | Two migrations that `CREATE OR REPLACE FUNCTION` the same function name — later definition wins without warning |
| Q3A | **Constraint drop + recreate** | A migration drops and recreates the same constraint (intentional refactor — informational, not a hard fail) |
| Q3B | **Constraint collision** | Two different migrations create the same constraint name — second `ALTER TABLE ADD CONSTRAINT` fails at apply time |

**How to run:**

Execute via the Gandalf MCP SQL tool (`execute_sql`) or directly against the
Supabase database:

```sql
-- Run the full audit (file: scripts/sql/p0_version_overwrite_audit_last_2_gens_proof_20260228.sql)
-- Replace with actual file contents once committed.
```

**Clean results (no findings):**

Each proof class returns zero rows when clean. Expected output:

```
Q0: 0 rows  -- no timestamp collisions
Q1: 0 rows  -- no view overwrites
Q2: 0 rows  -- no function overwrites
Q3B: 0 rows -- no constraint collisions
```

Q3A may return rows (intentional refactors) — these are informational, not
failures.

**Results with findings:**

Any non-zero result in Q0, Q1, Q2, or Q3B indicates an overwrite that needs
human review. The query returns the migration filenames, object names, and
the conflicting DDL statements.

---

## When to Run

| Trigger | Gate 1 (collision check) | Gate 2 (overwrite audit) |
|---------|--------------------------|--------------------------|
| **Pre-commit** (local) | Yes — fast, no DB needed | No — requires DB access |
| **PR preflight** (CI) | Yes — add to `deno-ci.yml` or `camber-preflight.yml` | Yes — via `invariant_gates.sh` or standalone SQL |
| **Pre-deploy** | Yes | Yes |
| **After multi-agent writes** | Yes — immediately | Yes — same session |

### CI Integration Status

| Workflow | File | Migration gate included? |
|----------|------|------------------------|
| Deno CI | `.github/workflows/deno-ci.yml` | Not yet — candidate for addition |
| CAMBER Preflight | `.github/workflows/camber-preflight.yml` | Not yet — candidate for addition |
| Deploy Edge Functions | `.github/workflows/deploy-edge-functions.yml` | N/A (functions only) |
| Invariant Gates (DB) | `scripts/invariant_gates.sh` (in `deno-ci.yml`) | Runs DB-level gates; does not include file-level collision check |

**Recommended addition** to `deno-ci.yml`:

```yaml
  migration-collision-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check migration version collisions
        run: ./scripts/check_migration_version_collisions.sh
```

---

## Known Issue Log

| Date | Prefix | Files | Status | Owner |
|------|--------|-------|--------|-------|
| 2026-02-28 | `20260228161000` | 2 files collided at same timestamp | **Resolved** — renamed to `20260228161200` | DATA |
