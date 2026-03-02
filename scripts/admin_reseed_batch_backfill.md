# admin_reseed_batch_backfill.py

Batch orchestration helper for Phase 2 segmentation backfill.

## What it does

1. Loads all `interactions.interaction_id` (excludes `is_nonsegmentable=true`)
2. Loads all `conversation_spans` with `is_superseded=false`
3. Computes candidates with no active spans
4. Calls `admin-reseed` for each candidate with:
   - Rate limiting (default max `5/min`)
   - Per-call CSV logging
   - Failure capture for retry
   - Progress output every 50 interactions (default)

## Required env vars

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `EDGE_SHARED_SECRET`

## Usage

Dry run (candidate list only):

```bash
python3 scripts/admin_reseed_batch_backfill.py --dry-run
```

Run reseed-only mode:

```bash
python3 scripts/admin_reseed_batch_backfill.py \
  --mode resegment_only \
  --max-per-minute 5 \
  --progress-every 50
```

Run reseed + reroute mode:

```bash
python3 scripts/admin_reseed_batch_backfill.py \
  --mode resegment_and_reroute \
  --max-per-minute 5 \
  --progress-every 50
```

## Artifacts

Each run writes under:

`artifacts/reseed_backfill_<UTC_TIMESTAMP>/`

- `results.csv` - one row per interaction attempt
- `failed_interactions.txt` - interaction IDs that failed
- `summary.json` - run totals and artifact paths

## Coordination note for DEV-11

Use this script as the orchestration layer for full backfill execution. Start with
`--limit 10` for smoke validation, then scale.
