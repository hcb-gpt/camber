# TOOLS.md — Camber Tooling Reference

> Single entry point for every script, gate, and utility across the Camber workspace.
> Find any tool in under 30 seconds.

**Repos:** `camber-calls` (product), `orbit` (workspace/orchestration), `~/.camber/bin` (CLI wrappers)
**Prereq for most scripts:** `source ~/.camber/credentials.env` (or `source scripts/load-env.sh` from repo root)

---

## Quick Reference

| Tool | Command | What it does |
|------|---------|--------------|
| `edge-smoke-test.sh` | `cc/scripts/edge-smoke-test.sh [slug]` | Post-deploy smoke test (auth gate + 200 + JSON) |
| `invariant_gates.sh` | `cc/scripts/invariant_gates.sh` | CI hard-fail invariant checks |
| `gate_pack.sh` | `cc/scripts/gate_pack.sh` | Gate-pack SQL correctness (runs in txn, rolls back) |
| `secret-scan.sh` | `cc/scripts/secret-scan.sh --staged` | Scan for leaked secrets in git diffs |
| `proof_pack.sh` | `cc/scripts/proof_pack.sh <interaction_id>` | Full proof-pack for one interaction |
| `replay_call.sh` | `cc/scripts/replay_call.sh <id> [--reseed] [--reroute]` | End-to-end pipeline replay |
| `query.sh` | `cc/scripts/query.sh "SELECT ..."` | Read-only SQL runner |
| `score_module.sh` | `cc/scripts/score_module.sh <module> <entity_id>` | Score any module+entity combo |
| `tram-boot-test` | `~/.camber/bin/tram-boot-test --quick` | Quick TRAM + MCP health check |
| `tram-stress-test` | `~/.camber/bin/tram-stress-test` | Full TRAM end-to-end stress test |
| `preflight.sh` | `orbit/scripts/preflight.sh` | Verify tools, creds, and env |
| `verify-deployment.sh` | `orbit/scripts/verify-deployment.sh` | Post-deploy config verification |
| `safe-deploy.sh` | `orbit/scripts/safe-deploy.sh` | Guarded MCP server deploy |

> **Path aliases used below:** `cc` = `camber-calls`, `orbit` = `orbit`

---

## CI Gates

Scripts that block deploys and merges. Exit 0 = pass, non-zero = fail.

| Script | Command | Purpose |
|--------|---------|---------|
| **invariant_gates.sh** | `cc/scripts/invariant_gates.sh [--verbose\|--json]` | Non-bypassable CI gate checks across all invariants |
| **gate_pack.sh** | `cc/scripts/gate_pack.sh` | Executes `gate_pack.sql` in a rolled-back txn; emits `GATEPACK\|PASS` or `GATEPACK\|FAIL` |
| **gate_schema_prereqs.sh** | `cc/scripts/gate_schema_prereqs.sh` | Verifies required tables/columns exist before gates run |
| **secret-scan.sh** (cc) | `cc/scripts/secret-scan.sh --staged` | Pre-commit secret leak detection |
| **secret-scan.sh** (orbit) | `orbit/scripts/secret-scan.sh --staged` | Same for orbit repo |
| **check_duplicate_migration_versions.sh** | `cc/scripts/check_duplicate_migration_versions.sh` | Detect duplicate migration version prefixes |
| **check_migration_version_collisions.sh** | `cc/scripts/check_migration_version_collisions.sh` | Detect version prefix collisions in migrations |
| **xcodebuild_camberredline_guard.sh** | `cc/scripts/xcodebuild_camberredline_guard.sh` | iOS build gate — xcodebuild compile check |
| **verify-config-sync.sh** | `orbit/scripts/verify-config-sync.sh [--fix]` | Config drift checker (primitives/charter sync) |

---

## Diagnostics

Health checks, audits, probes, and monitoring.

### System Health

| Script | Command | Purpose |
|--------|---------|---------|
| **preflight.sh** | `orbit/scripts/preflight.sh [--tools-only\|--creds-only\|--quiet]` | Full environment readiness check (tools, creds, config) |
| **verify-deployment.sh** | `orbit/scripts/verify-deployment.sh` | Post-reorg/deploy config verification |
| **mcp-validate.sh** | `orbit/scripts/mcp-validate.sh` | Verify Claude Code MCP server connectivity |
| **check-edge-runtime-drift.sh** | `orbit/scripts/check-edge-runtime-drift.sh --project-ref <ref>` | Detect Edge Functions deployed from /tmp (out-of-git drift) |
| **test-credentials.sh** | `cc/scripts/test-credentials.sh` | Verify credential loading works |
| **load-env.sh** | `source cc/scripts/load-env.sh` | Load env vars for scripts (idempotent) |

### Pipeline Probes

| Script | Command | Purpose |
|--------|---------|---------|
| **edge-smoke-test.sh** | `cc/scripts/edge-smoke-test.sh [slug\|--all]` | Post-deploy smoke: auth gate (401) + auth pass (200) + valid JSON |
| **smoke_fail_closed.sh** | `cc/scripts/smoke_fail_closed.sh` | Verify fail-closed behavior (no partial writes on error) |
| **proof_pack.sh** | `cc/scripts/proof_pack.sh <interaction_id>` | Full proof-pack (spans + attributions + coverage) for one call |
| **score_module.sh** | `cc/scripts/score_module.sh <module> <entity_id>` | Score any module (attribution, project, etc.) |
| **span_char_offsets_nonnull_check.sh** | `cc/scripts/span_char_offsets_nonnull_check.sh [ids...]` | Regression check for span char offset integrity |
| **segmentation_regression_check.sh** | `cc/scripts/segmentation_regression_check.sh` | Segment-llm oversize/multi-topic regression harness |
| **striking_traceability_regression_canary.sh** | `cc/scripts/striking_traceability_regression_canary.sh` | Striking-signals call traceability canary |
| **lou-winship-regression-check.sh** | `cc/scripts/lou-winship-regression-check.sh` | Lou Winship call regression check |
| **consolidation_delta_probe.sh** | `cc/scripts/consolidation_delta_probe.sh --run-id <uuid>` | Probe consolidation output deltas for a journal run |
| **dual_metric_gate_helper.sh** | `cc/scripts/dual_metric_gate_helper.sh` | Journal persistence gate metric checks |
| **redline_perf_probe.sh** | `cc/scripts/redline_perf_probe.sh --base-url <url> [--runs N]` | Redline assistant latency profiling |
| **embed_acceptance_watch.sh** | `cc/scripts/embed_acceptance_watch.sh --write-baseline` | Embed-freshness acceptance metric comparison |
| **journal_embed_backfill_probe.sh** | `cc/scripts/journal_embed_backfill_probe.sh` | Probe journal-embed-backfill response contract |
| **semantic_xref_high_signal_proof.sh** | `cc/scripts/semantic_xref_high_signal_proof.sh` | Semantic crossref readiness snapshot + vector probes |
| **migration_drift_snapshot.sh** | `cc/scripts/migration_drift_snapshot.sh` | Read-only drift detector (remote vs local migrations) |

### Attribution Audit

| Script | Command | Purpose |
|--------|---------|---------|
| **process_attribution_audit_queue.sh** | `cc/scripts/process_attribution_audit_queue.sh` | Process audit queue through reviewer, persist to ledger |
| **prod_attrib_audit_reviewer_runner.sh** | `cc/scripts/prod_attrib_audit_reviewer_runner.sh` | End-to-end standing audit reviewer execution |
| **verify_audit_attribution_packet_v1.sh** | `cc/scripts/verify_audit_attribution_packet_v1.sh` | Verify packet-v1 reviewer path (build + invoke) |

### Spotcheck

| Script | Command | Purpose |
|--------|---------|---------|
| **spotcheck_bruteforce.sh** | `cc/scripts/spotcheck_bruteforce.sh` | Build per-call evidence packet for independent agent review |
| **spotcheck_bruteforce_batch.sh** | `cc/scripts/spotcheck_bruteforce_batch.sh [--count N]` | Run N brute-force spotchecks, write consolidated report |
| **spotcheck_queue.sh** | `cc/scripts/spotcheck_queue.sh` | Run spotcheck SQL for one interaction |

---

## iOS

Build, test, and smoke for CamberRedline iOS app.

| Script | Command | Purpose |
|--------|---------|---------|
| **xcodebuild_camberredline_guard.sh** | `cc/scripts/xcodebuild_camberredline_guard.sh` | CI build gate — compiles CamberRedline scheme |
| **ios_simulator_smoke_drive.sh** | `cc/scripts/ios_simulator_smoke_drive.sh` | Full simulator smoke test (build + boot + screenshot) |
| **morning_manifest_ui_smoke.sh** | `cc/scripts/morning_manifest_ui_smoke.sh` | Smoke test for morning-manifest-ui JSON and HTML modes |

---

## Pipeline

Call processing, replay, backfill, and evaluation tools.

### Replay & Reseed

| Script | Command | Purpose |
|--------|---------|---------|
| **replay_call.sh** | `cc/scripts/replay_call.sh <id> [--reseed] [--reroute] [--verbose]` | End-to-end pipeline replay for one interaction |
| **shadow_batch_replay.sh** | `cc/scripts/shadow_batch_replay.sh` | Shadow replay for a batch of interactions |
| **shadow_batch_phase2.sh** | `cc/scripts/shadow_batch_phase2.sh` | Phase 2: find gaps/zero-spans, batch replay them |
| **admin_reseed_batch_backfill.py** | `python3 cc/scripts/admin_reseed_batch_backfill.py` | Batch admin-reseed backfill orchestrator |

### Evaluation & Ground Truth

| Script | Command | Purpose |
|--------|---------|---------|
| **p2-eval-scorer.sh** | `cc/scripts/p2-eval-scorer.sh [--blind-trial-only]` | P2 paired A/B eval (McNemar's test, stratified accuracy) |
| **gt_batch_runner.sh** | `cc/scripts/gt_batch_runner.sh` | Ground truth batch runner |
| **gt_pick_fresh_review_items_v1.sh** | `cc/scripts/gt_pick_fresh_review_items_v1.sh` | Pick fresh review items for GT labeling |
| **gt_rerun_proof_harness.sh** | `cc/scripts/gt_rerun_proof_harness.sh --phase <before\|after> <ids...>` | GT rerun proof (before/after comparison) |
| **temporal_backtest_harness.sh** | `cc/scripts/temporal_backtest_harness.sh` | Temporal backtest harness |

### Assistants & Redline

| Script | Command | Purpose |
|--------|---------|---------|
| **redline_assistant_harness.sh** | `cc/scripts/redline_assistant_harness.sh "question"` | CLI harness for redline-assistant Edge Fn |
| **redline-assistant-winship-harness.sh** | `cc/scripts/redline-assistant-winship-harness.sh` | Winship-specific redline assistant harness |

### Journal & Extraction

| Script | Command | Purpose |
|--------|---------|---------|
| **batch_journal_extract.sh** | `cc/scripts/batch_journal_extract.sh` | Batch journal-extract for calls with spans but no claims |
| **backfill-review-span-extraction.sh** | `cc/scripts/backfill-review-span-extraction.sh [--dry-run] [--limit N]` | Journal-extract backfill for review spans missing claims |
| **review_span_extraction_backfill.sh** | `cc/scripts/review_span_extraction_backfill.sh` | Journal-extract against review-gated spans (confidence >= 0.70) |

### Regression Acceptance

| Script | Command | Purpose |
|--------|---------|---------|
| **pr64_bethany_road_acceptance.sh** | `cc/scripts/pr64_bethany_road_acceptance.sh` | PR #64 acceptance test (Bethany Road) |
| **scan-transcript-regression-sample.sh** | `cc/scripts/scan-transcript-regression-sample.sh` | Transcript regression sample scanner |

---

## Data

SQL queries, migration tools, backfills, and proofs.

### Read-Only Queries

| Script | Command | Purpose |
|--------|---------|---------|
| **query.sh** | `cc/scripts/query.sh "SELECT ..."` | Canonical read-only SQL runner |
| **query.sh --file** | `cc/scripts/query.sh --file scripts/daily_digest.sql` | Run SQL from a file |
| **daily_digest.sql** | `cc/scripts/query.sh --file scripts/daily_digest.sql` | Daily digest summary query |

### Migration Tools

| Script | Command | Purpose | Prereqs |
|--------|---------|---------|---------|
| **migration_apply_guarded.sh** | `cc/scripts/migration_apply_guarded.sh` | Write-mode migration wrapper with claim/session guard | `ORIGIN_SESSION`, `CLAIM_RECEIPT` |
| **migration_drift_snapshot.sh** | `cc/scripts/migration_drift_snapshot.sh` | Read-only: detect remote-vs-local migration drift | — |
| **claim_guard.sh** | `source cc/scripts/claim_guard.sh` | Shared preflight for write-mode scripts (ownership context) | — |

### SQL Audits (`scripts/sql/`)

| File | Purpose |
|------|---------|
| `attribution_audit_packet_v1.sql` | Build audit packet for one interaction |
| `attribution_audit_sample_v1.sql` | Sample interactions for audit |
| `prod_attrib_audit_pending_packets.sql` | Pending audit packets |
| `prod_attrib_audit_sampler_and_recorder.sql` | Audit sampler + recorder |
| `stopline_call_evidence_coverage_proof_24h.sql` | Stopline: call evidence coverage (24h) |
| `stopline_r1_uncovered_active_spans_check.sql` | Stopline: uncovered active spans |
| `span_attribution_coverage_last30d.sql` | Span attribution coverage (30d) |
| `span_oversize_last30d.sql` | Oversize spans (30d) |
| `interactions_errors_last30d.sql` | Interaction errors (30d) |
| `review_queue_junk_candidates_v1.sql` | Review queue junk candidates |
| `review_queue_pending_null_span.sql` | Review queue: pending with null span |
| `review_queue_pending_on_superseded_span.sql` | Review queue: pending on superseded span |
| `ci_gates_summary.sql` | CI gates summary |
| `r1_zero_promotion_runid_guard_check.sql` | R1 zero-promotion runid guard check |
| `rpc_run_daily_audit_sample_v1.sql` | RPC: run daily audit sample |

### SQL Proofs (`scripts/sql/proofs/`)

| File | Purpose |
|------|---------|
| `attributions_to_closed_projects_last30d.sql` | Attributions to closed projects |
| `interaction_transcript_parent_mismatch_v1.sql` | Transcript parent mismatches |
| `project_facts_missing_provenance.sql` | Project facts without provenance |
| `project_facts_window_counts.sql` | Project facts window counts |
| `span_attribution_coverage_for_interaction_template.sql` | Per-interaction attribution coverage |

### Backfill SQL (`scripts/backfills/`)

| File | Purpose |
|------|---------|
| `interaction_transcript_parent_sync_v1.sql` | Sync interaction transcript parents |
| `span_attributions_double_covered_gate_fix_v0.sql` | Fix double-covered span attributions |
| `review_queue_junk_prefilter_cleanup_v1.sql` | Cleanup junk in review queue |
| `review_queue_superseded_span_hygiene_v0.sql` | Superseded span hygiene |
| `speaker_backfill_pilot_apply_v0.sql` | Speaker resolution backfill (apply) |
| `speaker_backfill_pilot_rollback_v0.sql` | Speaker resolution backfill (rollback) |
| `deepgram_transcripts_dedupe_v0.sql` | Deduplicate Deepgram transcripts |

### Proof Scripts (`scripts/proofs/`)

| File | Purpose |
|------|---------|
| `global_pipeline_drift_metrics_v0.sql` | Global pipeline drift metrics |
| `owner_identity_metrics_pack_v1.sql` | Owner identity metrics pack |
| `review_queue_noise_classification_v0.sql` | Review queue noise classification |
| `admin_reseed_dupkey_race_proof.sh` | Admin reseed duplicate-key race proof |
| `homeowner_override_proof_runner.py` | Homeowner override proof runner |

### World Model (`scripts/world_model/`)

Ground truth labeling pipeline (Deno/TypeScript).

| File | Purpose |
|------|---------|
| `gt_eval.ts` | Ground truth evaluator |
| `labeling_pipeline.ts` | Orchestrates the full labeling pipeline |
| `pass0_deterministic.ts` | Pass 0: deterministic matching |
| `pass1_graph_propagation.ts` | Pass 1: graph-based label propagation |
| `pass2_haiku_triage.ts` | Pass 2: Haiku triage for ambiguous cases |
| `pass3_opus_deep_label.ts` | Pass 3: Opus deep labeling |
| `pass4_review_queue.ts` | Pass 4: human review queue generation |
| `seed_jsonl_to_sql.ts` | Convert seed JSONL to SQL inserts |

---

## MCP

The Camber MCP server provides TRAM messaging, Orbit doc fetching, Camber Map queries, and session management.

- **Server URL:** `https://camber-mcp-78779153677.us-central1.run.app`
- **Validate connectivity:** `orbit/scripts/mcp-validate.sh`
- **Deploy:** `orbit/scripts/safe-deploy.sh [--dry-run]`
- **Server source:** `orbit/apps/mcp-server/`

### MCP Tool Categories (13 registered tools)

| Category | Tools |
|----------|-------|
| **Fetch** | `search`, `fetch` |
| **TRAM** | `tram_create`, `tram_ack`, `tram_unacked`, `tram_my_queue`, `tram_search`, `tram_status`, `tram_work_items` |
| **Camber Map** | `camber_map_query`, `camber_map_facts` |
| **Session** | `session_register`, `session_heartbeat`, `session_retire`, `session_list` |

---

## Agent Tooling

TRAM messaging, session management, and workspace utilities.

### TRAM CLI & Maintenance

| Script | Command | Purpose |
|--------|---------|---------|
| **tram** | `~/.camber/bin/tram <command> [args]` | CLI wrapper for TRAM MCP (create, list, search) |
| **tram-boot-test** | `~/.camber/bin/tram-boot-test [--quick]` | Session boot health check (MCP, proxy, 13 tools, Supabase) |
| **tram-stress-test** | `~/.camber/bin/tram-stress-test` | Full TRAM stress test (Git sync, Drive mirror, creation, GitHub API, Supabase) |
| **tram-mirror** | `~/.camber/bin/tram-mirror [--once\|--verbose]` | Mirror GitHub TRAM to local Drive (continuous 2s loop or one-shot) |
| **tramcheck.sh** | `orbit/scripts/tramcheck.sh [ROLE] [session] [--json]` | Session-aware TRAM queue snapshot from Supabase |
| **tram-no-mcp-queue.sh** | `orbit/scripts/tram-no-mcp-queue.sh <ROLE> [limit] [--unacked\|--open\|--summary]` | TRAM queue when MCP is down (direct Supabase query) |
| **tram-maintenance.sh** | `orbit/scripts/tram-maintenance.sh [--execute]` | Run all TRAM housekeeping (mark superseded, archive, report) |
| **tram-archive.sh** | `orbit/scripts/tram-archive.sh [--execute]` | Archive TRAM messages older than 24h |
| **tram-mark-superseded.sh** | `orbit/scripts/tram-mark-superseded.sh` | Mark parent TRAM messages as superseded via IN_REPLY_TO |
| **tram_backfill_v2.ts** | `deno run orbit/scripts/tram_backfill_v2.ts [--dry-run]` | Backfill TRAM messages from Supabase DB to GitHub + Drive |
| **tram_cold_sessions.py** | `python3 orbit/scripts/tram_cold_sessions.py` | Detect cold/silent agent sessions from TRAM message history |

### Session & Workspace

| Script | Command | Purpose |
|--------|---------|---------|
| **orbit-launch.sh** | `orbit/scripts/orbit-launch.sh <gemini\|claude> <role>` | Unified launcher for Gemini/Claude agent sessions |
| **sync-orbit-docs.sh** | `orbit/scripts/sync-orbit-docs.sh` | Upsert Orbit docs from git into Supabase `orbit_docs` |
| **install.sh** | `orbit/scripts/install.sh` | Set up `~/.camber` as symlink bridge to orbit scripts |
| **keychain-import.sh** | `orbit/scripts/keychain-import.sh [path]` | Import credentials.env into macOS Keychain |
| **load-credentials.sh** | `source orbit/scripts/load-credentials.sh` | Load creds (Keychain-first, then file fallback) |
| **replay-eval.sh** | `orbit/scripts/replay-eval.sh [--dry-run\|--call <id>\|--limit N]` | P0 Step 5: Replay labeled calls through P1 pipeline vs ground truth |

### CLI Wrappers (`~/.camber/bin/`)

| Wrapper | Purpose |
|---------|---------|
| **claude** | Workspace wrapper for `claude` — loads creds + env |
| **codex** | Workspace wrapper for `codex` — loads creds + env |
| **context-pack** | Generate context packs (`--full\|--lite [--copy] [--repo <name>]`) |
| **initialize-camber** | Bootstrap a new Camber workspace |
| **beside-sqlite-sync.py** | Sync Beside (TheMessagingApp) SQLite to Supabase |

---

## Beside (SMS/Messaging)

| Script | Command | Purpose |
|--------|---------|---------|
| **beside-sqlite-sync.py** | `~/.camber/bin/beside-sqlite-sync.py [--full\|--dry-run]` | Sync local Beside SQLite DB to Supabase |
| `beside_direct_read/` | `cc/scripts/beside_direct_read/` | Direct-read utilities for Beside data |
| `beside_thread_events_parity_proof_v0.sql` | SQL proof for thread events parity |

---

## Credential Setup (first-time)

```bash
# 1. Import credentials into macOS Keychain
orbit/scripts/keychain-import.sh

# 2. Verify everything loads
orbit/scripts/preflight.sh

# 3. Verify MCP connectivity
orbit/scripts/mcp-validate.sh

# 4. Run quick boot test
~/.camber/bin/tram-boot-test --quick
```

---

*Generated 2026-02-28. Canonical paths: `camber-calls` = `/Users/chadbarlow/gh/hcb-gpt/camber-calls`, `orbit` = `/Users/chadbarlow/gh/hcb-gpt/orbit`.*
