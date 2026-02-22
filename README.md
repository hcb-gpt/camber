# CAMBER Edge Functions

Supabase Edge Functions for the CAMBER call processing pipeline.

## Structure

```
camber-edge-functions/
├── .github/
│   └── workflows/
│       └── deploy-edge-functions.yml   # Auto-deploy on push to main
├── supabase/
│   ├── config.toml                     # Project config
│   └── functions/
│       └── process-call/
│           └── index.ts                # v3.8 call pipeline
└── README.md
```

## Functions

### process-call

Full v3.6+ call processing pipeline:
- Idempotency check
- Event audit (write-ahead)
- M1: Normalize payload
- Contact lookup (RPC)
- Project attribution
- M4: Gatekeeper
- Persist to `calls_raw`, `interactions`
- Final audit update

**Endpoint:** `https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/process-call`

## Local Development

```bash
# Install Supabase CLI
brew install supabase/tap/supabase

# Link to project
supabase link --project-ref rjhdwidddtfetbwqolof

# Serve locally
supabase functions serve process-call --env-file .env.local

# Deploy manually
supabase functions deploy process-call --no-verify-jwt
```

## Read-Only SQL Access

For DATA/DEV sessions, use:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
scripts/query.sh "select now();"
```

Details: `docs/data_sql_access.md`

## Timeline Quality Audit

For a fast join-integrity check of `project_timeline_events` (without `psql`):

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
scripts/timeline_quality_audit.sh --days 7 --out .temp/timeline_audit.json
```

The script validates references against `projects`, `contacts`, and `interactions`,
then prints a JSON report with counts plus sample suspect rows.

To enforce thresholds in CI or cron checks:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
scripts/timeline_quality_gate.sh --days 7
```

The gate exits non-zero on threshold violations and supports overrides such as
`--max-missing-contact-id-rows 10`.
It also supports event-type-aware checks, for example
`--allowed-missing-contact-event-types permit_submitted,attribution_landed --max-unexpected-missing-contact-id-rows 0`.
For human-readable output from an audit JSON, run:
`scripts/timeline_quality_summary.sh --report .temp/timeline_audit.json`.
GitHub Actions workflow: `.github/workflows/timeline-quality-gate.yml` (daily + manual run).

## Migration Collision Guard

To catch duplicate migration version prefixes before `supabase db push --include-all`:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
scripts/check_migration_version_collisions.sh
```

Exit code `1` means at least one version prefix has multiple SQL files and should
be reconciled before applying migrations.

## Consolidation Delta Probe

For fast troubleshooting when consolidation appears to run but `module_*` tables
show no movement:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
./scripts/consolidation_delta_probe.sh --run-id <journal_run_uuid>
```

Useful flags:

- `--no-invoke`: read-only snapshot without calling `journal-consolidate`
- `--json`: structured output for automation/parsing

The probe reports:

- `journal_claims` count for the run
- before/after counts for `module_claims` and `module_receipts`
- function HTTP status and body (unless `--no-invoke`)

## Embed Acceptance Watch

For fast DATA/DEV co-review of embed freshness acceptance (with a built-in
PASS/FAIL verdict):

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
scripts/embed_acceptance_watch.sh --write-baseline
scripts/embed_acceptance_watch.sh --compare
```

Useful flags:

- `--baseline-file <path>`: use a custom baseline snapshot file
- `--max-runid-mismatch-increase <n>`: allow limited mismatch increase (default `0`)
- `--json`: machine-readable output for receipt generation/automation

## SMS Ingestion Restore Probe

For stage-by-stage validation of `zapier-call-ingest -> process-call`:

```bash
cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
./scripts/sms_ingestion_restore_probe.sh --mode canonical
```

Useful flags:

- `--mode canonical|legacy|both`
- `--no-write` (validation-only forward check; no intended persistence)
- `--json` (machine-readable output for automation)

## CI/CD

Push to `main` triggers automatic deployment via GitHub Actions.

**Required GitHub Secrets:**
- `SUPABASE_ACCESS_TOKEN` - From [Supabase Dashboard](https://supabase.com/dashboard/account/tokens)
- `SUPABASE_PROJECT_ID` - `rjhdwidddtfetbwqolof`

## Versioning

Edge function versions tracked in code comments and `router_version` field written to `idempotency_keys`.

| Version | Date | Changes |
|---------|------|---------|
| v3.8.3 | 2026-01-30 | Initial Git-tracked version |
| v3.8.2 | 2026-01-30 | Fixed interactions schema |
| v3.8.1 | 2026-01-30 | Fixed contact_id extraction |
| v3.8.0 | 2026-01-30 | Initial Edge Function port |

## Related

- **Pipeline Entry Point:** `https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/process-call`
- **Supabase Project:** `rjhdwidddtfetbwqolof`
- **Replay/Shadow:** TODO — define direct Edge-native replacement workflow
