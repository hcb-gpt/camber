# CLAUDE.md — CAMBER v4 Operating Manual

This is the single “boot + contract” doc for v4. If it’s not here, it’s not a rule.
Status codes are not proof. DB deltas are proof.

---

## Local Session Boot (Claude Code / Desktop)

If the user’s first message is a role statement (examples: “you are strat”,
“you are dev”, “set role data”), treat it as session role selection. Valid roles
are: `CHAD`, `DEV`, `DATA`, `STRAT`.

Immediately after role is set, boot via MCP by fetching these four Orbit docs
(canonical IDs; no duplicates):

1) `boot-protocol`
2) `roles`
3) `role-boundaries`
4) `charter`

Use whichever Orbit/Camber fetch tool is available (e.g. `mcp__camber__fetch`,
`orbit.fetch`, MCP connector, or equivalent) with `id="<slug>"`.

If any fetch fails (blocked / not_found / empty), stop and report via TRAM:

- Tool: whichever TRAM create tool is available (e.g. `mcp__camber__tram_create`
  or equivalent MCP connector)
- `to="STRAT"`, `from=SESSION_ROLE`
- `subject="boot_failed_" + SESSION_ROLE`
- `kind="test"`, `priority="high"`, `thread="boot"`
- Content includes `ORIGIN_AGENT`, `ORIGIN_PLATFORM`, `ORIGIN_SESSION`, and the
  exact error text

Do **not** fetch `founding-policies` during boot; it is legacy and must not be
required.

## Authoritative Role Policy (2026-02-06)

TRAM roles are strictly limited to:
- CHAD (human)
- DEV
- DATA
- STRAT

Rules:
- Roles are platform-agnostic (no GPT_BROWSER, no KAIZEN, no SYSTEM, no ALL).
- Browser-run agents must participate by explicitly selecting one of the four roles at runtime.
- No sender remap/fallback is permitted.
- Platform identity belongs in origin metadata (e.g., `ORIGIN_PLATFORM`, `ORIGIN_CLIENT`, `ORIGIN_SESSION`), not in `FROM:`.
- Labels like “GPT-DEV”, “DEV-1”, “DATA-1”, “CAMBER-1” are lane labels/specializations, not TRAM roles; do not use them in `TO:`/`FROM:`.


## Immune System Mode (Shared Capability)

Canonical policy lives in Orbit: `orbit/docs/immune_system_mode.md`.

Every role can temporarily enter **Immune System Mode** when needed.
Immune System Mode is **observe + diagnose + recommend** — do not execute fixes outside your role boundary.

### Master trigger
**A007 HUMAN_TRUST** is the Andon cord.
If Chad signals distrust/frustration ("something is off", "this is wrong", etc.), immediately:
1) stop current work
2) check TRAM + system health
3) diagnose and propose the smallest corrective plan

### Andon signals (A001–A008)
- **A001 CONTEXT_INTEGRITY** — Are we still talking about the same thing?
- **A002 FLOW_CONTROL** — Are we stuck or oscillating?
- **A003 AUTHORITY_BOUNDARY** — Who is allowed to decide/execute this?
- **A004 CONFIDENCE_EVIDENCE** — Is certainty earned by proof?
- **A005 MEMORY_COMPRESSION** — Did we summarize too hard / lose nuance?
- **A006 COST_LATENCY_DRIFT** — Is effort still proportional?
- **A007 HUMAN_TRUST** — The user no longer trusts the system. (master trigger)
- **A008 META_ANDON** — Something feels wrong but we don't know why.

### Protocol (5 Whys)
1) What happened?
2) What should have prevented it?
3) Why did that fail?
4) What is the smallest fix that prevents recurrence?
5) What is the proof that the fix works on new events?


## Environment Stamp (required on every substantive edit)

Repo:
- org/repo:
- branch:
- HEAD (sha + subject):
Supabase:
- project ref:
- functions deployed (names only):
Stamp Date (UTC):

---

## A) Mission and stoplines

### Mission (one sentence)
v4 adds LLM-powered segmentation so that a multi-project call produces **N spans → N attributions** (or fails closed), instead of forcing one project per call.

### Stoplines (never break)
1) SSOT for routing output is `span_attributions` (the row). `interactions.project_id` is not AI truth and must not be written by AI.
2) Truth promotion is monotonic: human overrides AI; AI must never override human; null never overwrites non-null.
3) Fail closed on required writes: if a required DB write fails, return **500** + `error_code`. No silent “200 OK.”

---

## B) Roles and division of labor (lane rules)

TRAM roles (`TO:`/`FROM:`) are only: **CHAD**, **DEV**, **DATA**, **STRAT**.

Responsibility lanes (NOT TRAM roles):
- **STRAT** routes work and defines acceptance tests.
- **DEV** executes patches, runs tests, deploys, rotates secrets, posts receipts.
- **DATA** owns DB migrations/constraints/views/RPCs and post-deploy measurement.
- **CHAD** resolves tradeoffs and conflicts; no execution tasks.

Non-role labels you may see in older docs (do not use in `TO:`/`FROM:`):
- “GPT-DEV-*” = code-writing assistants (diffs/PRs/test steps/rollback notes; no deploys)
- “DATA-*” = data workers (delegated by DATA)
- “CAMBER-*” = review gate / stopline enforcement

## C) TRAM + async comms protocol (enforced)

TRAM path (messages + downloads):
`/Users/chadbarlow/Library/CloudStorage/GoogleDrive-admin@heartwoodcustombuilders.com/My Drive/_camber/Camber/01_TRAM/`

TRAM message filename format (legacy; do not rely on it):
`{TO}_{FROM}_{YYYYMMDDTHHMM}Z_{SUBJECT}.md`

Rules:

- `TO:`/`FROM:` must be one of `CHAD`, `DEV`, `DATA`, `STRAT`.
- Do not invent roles (no GPT_BROWSER, no KAIZEN, no SYSTEM, no ALL).
- If you need platform tagging, put it in origin metadata (e.g., `ORIGIN_PLATFORM`, `ORIGIN_CLIENT`, `ORIGIN_SESSION`), not in `FROM:`.
- First token (TO) is the recipient so Chad can route without opening.
- ≤50 words narration (code blocks don’t count).
- Use tags:
  - `⚡ CHAD:` needs a human decision
  - `🚫 BLOCKED:` cannot proceed
  - `✅ DONE:` task complete

BLOCKED protocol:
1) what is blocked
2) why
3) what decision/info unblocks
4) who can unblock
No guesswork and no workarounds.

Auth/collision escalation (Charter §9-10):
- Any 401/403/secret mismatch → STRAT immediately via TRAM (priority=HIGH). Same turn.
- Two agents writing same resource → STRAT immediately via TRAM (priority=HIGH). Same turn.
- Include evidence: failing function/resource, caller/agents, auth method, status code.

Deploy/commit ownership (Charter §11):
- Declare deploy intent via TRAM BEFORE deploying or committing to shared resources.
- One owner per resource at a time. If claimed, coordinate first.
- Commit after every deliverable. End-of-session commit required.
- Deploy receipts must include: DEPLOY_PROOF, supabase_version, verify_jwt setting.

---

## D) Message headers + receipts (mechanically verifiable)

Every message begins with:
`TO:<role> FROM:<role> TURN:<n> TS_UTC:<YYYY-MM-DDTHH:MMZ> RECEIPT:<artifact>`

Allowed roles for `TO:`/`FROM:`: `CHAD`, `DEV`, `DATA`, `STRAT`.

Allowed RECEIPT formats (choose one primary):
- `PR#<n>/headSHA:<sha>/CI:<pass|fail>`
- `commit:<sha>`
- `deploy:<slug>/<sha>`
- `sql:<migration|view|fn>/<name>`
- `metric:<name>=<value>`

Valid review targeting:
- Review is valid only for the PR **headSHA** at review time.
- If headSHA changes, review is void.

“Stamp” requirement for ready/review/merge:
- PR#, baseRef, headRef, headSHA
- CI proof (link or checks output)
- diff source (PR diff output)

---

## E) Anti-drift protocol (v2)

Drift = prod (runtime) differs from git (reviewable truth).

### Closing edge-function drift (REQUIRED)
Drift is closed only when BOTH are true:
1) Function source exists in git on main at `supabase/functions/<slug>/...`
2) Deploy is traceable to a git commit on main via receipt: `deploy:<slug>/<sha>`

No dashboard edits rule:
- Do not edit function code in Supabase Dashboard.
- If an emergency dashboard edit happens anyway, within 24 hours:
  - export/download the function source,
  - commit it to git,
  - open PR with stamp,
  - merge + redeploy from git,
  - post `deploy:<slug>/<sha>` receipt.
If not closed in 24h: feature freeze until closed (unless Chad waives explicitly).

### Closing migration drift (REQUIRED)
Drift is closed only when BOTH are true:
1) remote migration history is aligned (apply/repair)
2) migration files exist in git on main (PR merged)

---

## F) v4 Sprint 0 deliverable — LLM segmenter

### Problem statement
Current segmenting is trivial (1 call = 1 span). Multi-project calls get forced into one attribution. v4 fixes that by segmenting into multiple spans before routing.

### New component: `segment-llm`
Canonical slug: `segment-llm`
Called from: `segment-call`

Auth (internal pattern):
- `verify_jwt=false`
- Requires `X-Edge-Secret == EDGE_SHARED_SECRET`
- Requires provenance `source` in allowlist (minimum: `segment-call`, `edge`, `test`)
Optional debug auth (only if needed): verified JWT via `auth.getUser()` + allowlist.
Explicitly banned: decoding JWT payload and trusting it without verification.

Input:
```json
{
  "interaction_id": "cll_...",
  "transcript": "optional; if missing, segment-llm may fetch from calls_raw",
  "source": "segment-call",
  "max_segments": 10,
  "min_segment_chars": 200
}
```

Output (JSON only):
```json
{
  "ok": true,
  "segmenter_version": "segment-llm_v1.0.0",
  "segments": [
    {
      "span_index": 0,
      "char_start": 0,
      "char_end": 2847,
      "boundary_reason": "topic_shift",
      "confidence": 0.85,
      "boundary_quote": "…now about the Hurley job…"
    }
  ],
  "warnings": []
}
```

Guardrails:
- Clamp boundaries into [0, len(transcript)]
- Segments must be increasing, non-overlapping, and contiguous (cover full transcript)
- Enforce `min_segment_chars` by merging undersized segments into previous
- Enforce `max_segments` by merging low-confidence boundaries

Fallback:
- If the LLM fails or output is invalid, return one full-call segment with `warnings=["llm_failed_fallback"]`.

Segmenter never does:
- never assigns project truth
- never writes DB
- never drops transcript content

---

## G) Orchestration (call → N spans → N attributions)

Chain:
`process-call → segment-call → segment-llm → (for each span) context-assembly → ai-router`

`segment-call` responsibilities (v4):
1) Fetch transcript (from request or calls_raw)
2) Call `segment-llm` to get boundaries
3) Upsert N rows into `conversation_spans` (span_index 0..N-1, char offsets, transcript_segment substring, word_count, segmenter_version, segment_reason, optional metadata)
4) For each span: call `context-assembly`, then `ai-router` (forward `dry_run`)

Idempotency:
- Span key is `(interaction_id, span_index)`
- Reseed rule (Sprint 0):
  - If any `span_attributions` exist for the interaction’s spans: do NOT re-segment. Return **409** with `error_code="already_attributed"` (or no-op with warning). No destructive reseeding without explicit CAMBER-1 approval.

DB note:
- Storing boundary confidence/quote cleanly is easier with `conversation_spans.segment_metadata jsonb`. If missing, add a migration (DATA-1).

---

## H) Attribution uniqueness decision gate (DATA-A + DATA-1)

We must choose and enforce ONE meaning:

Option A — canonical per span (simple):
- enforce `UNIQUE(span_id)` for `span_attributions`
- router upserts on `span_id`
- pro: one truth row
- con: loses prediction history

Option B — history per (model,prompt) (forensics/eval):
- enforce `UNIQUE(span_id, model_id, prompt_version)`
- router upserts on that composite
- pro: preserves evolution
- con: downstream must query “current” by prompt/version or latest timestamp

Until decided: do not change constraints silently; document which option is active in the Environment Stamp.

---

## I) Acceptance tests (DEV executes)

Synthetic multi-project (forced switch):
- Use a transcript with an explicit switch (“Now about Hurley… also Skelton…”)
- Expected: `conversation_spans` count >= 2 and offsets valid

Write-run proof (dry_run=false):
- Expected: span count = attribution row count for that interaction
- If any required write fails: HTTP 500 + `error_code`

Single proof query (standard):
```sql
SELECT
  cs.span_index,
  cs.id AS span_id,
  sa.decision,
  sa.project_id,
  sa.applied_project_id,
  sa.confidence,
  sa.attribution_lock,
  sa.model_id,
  sa.prompt_version,
  sa.attributed_at
FROM conversation_spans cs
LEFT JOIN span_attributions sa ON sa.span_id = cs.id
WHERE cs.interaction_id = '<interaction_id>'
ORDER BY cs.span_index;
```

Success criteria:
- `span_index` is 0..N-1 with no gaps
- attribution rows present for each span (or chain failed closed)
- decision in ('assign','review','none')

Protocol marker:
- You may write **CHAIN WRITE VERIFIED** only after the query above shows N spans and N attribution rows (or after a fail-closed 500 is observed with logged `error_code`).

## Agent Teams
Always propose and use agent teams for any non-trivial task.
Default to spawning specialized teammates rather than working sequentially.
