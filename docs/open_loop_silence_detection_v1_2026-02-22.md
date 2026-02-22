# Open Loop Silence Detection v1 (2026-02-22)

## Objective
Detect when a promised follow-up has likely gone stale so operators are alerted before they manually remember and chase it.

## Architecture Snapshot (Camber Map)
- `journal_claims` is fed by `journal-extract`/`journal-consolidate` and is the commitment/deadline source.
- `journal_open_loops` is fed by `journal-extract` and `loop-closure`, and tracks unresolved loops.
- `review_queue` tracks attribution/triage debt and is already consumed by summary surfaces.
- `call_chains` is written by `chain-detect` and provides temporal-contact context.
- `v_morning_manifest` already depends on `journal_claims`, `review_queue`, and `striking_signals`; silence signals can feed the same consumption layer.

## Problem in Current Schema
- `journal_claims` has `claim_type='deadline'|'commitment'`, but no normalized due timestamp.
- `journal_open_loops` has `status`, `closed_at`, and closure evidence, but no explicit expected follow-up window.
- Result: a deadline can age out silently with no first-class "missed promise" object.

## Proposed Data Model
Add two read-model tables (or equivalent views first, then tables if needed):

1. `open_loop_expectations`
- `expectation_id uuid pk`
- `claim_id uuid` (source commitment/deadline claim)
- `call_id text`
- `project_id uuid`
- `contact_phone text`
- `expected_action text`
- `due_at_utc timestamptz`
- `due_confidence numeric`
- `due_parse_method text` (`explicit_date`, `relative_phrase`, `fallback_window`)
- `created_at_utc timestamptz`

2. `open_loop_silence_events`
- `silence_event_id uuid pk`
- `expectation_id uuid`
- `state text` (`open`, `acknowledged`, `resolved`, `suppressed`)
- `silence_started_at_utc timestamptz`
- `last_checked_at_utc timestamptz`
- `follow_up_call_id text null`
- `resolved_at_utc timestamptz null`
- `suppression_reason text null`
- unique key on `(expectation_id, state='open')` to keep idempotent active alerts

## Detection Logic (v1)
1. Candidate extraction
- Source claims from `journal_claims` where `claim_type in ('deadline','commitment')` and `active=true`.
- Join contact/project context via `interactions` and project fallback (`claim_project_id_norm`, `claim_project_id`, `project_id`).

2. Due-time resolution
- If explicit date/time is present in claim text, parse to `due_at_utc`.
- If relative phrase only (for example "tomorrow", "next Monday"), resolve against call timestamp.
- If unresolved, assign conservative fallback window (`claim_created_at + 48h`) and mark lower `due_confidence`.

3. Silence scoring
- For each expectation past `due_at_utc`, query for follow-up interactions from same contact after due time.
- If no follow-up and no closure evidence in `journal_open_loops`, emit/maintain `open_loop_silence_events(state='open')`.
- Optionally upweight with `call_chains` context:
  - low recent chain activity + stale expectation => higher urgency
  - recent active chain => lower urgency or defer

4. Closure
- Auto-close when follow-up interaction appears or `journal_open_loops` closes with evidence.
- Never hard-delete; keep events for auditability.

## Alerting Approach
- Primary surface: include `silence_events_open` in morning brief payload grouped by project.
- Secondary surface: add a high-priority queue lane for unresolved silence events older than threshold (e.g., 24h past due).
- Alert payload fields:
  - project
  - contact
  - promise/deadline excerpt
  - due_at
  - hours overdue
  - latest related call timestamp
  - direct pointers (`claim_id`, `call_id`, optional `open_loop_id`)

## Real Data Pointer (Live Query)
Use:
- `scripts/open_loop_silence_candidates.sql`
- Run via: `./scripts/query.sh --file scripts/open_loop_silence_candidates.sql`

Live run on 2026-02-22 UTC returned 3 candidates with no detected follow-up calls and claim age >48h, including:
- `claim_id=da5ce960-43db-4d4e-bb17-a46b0e466fa1` (`call_id=cll_06E0ARC879S855FPXM71S6EBJR`)
- `claim_id=93b1b5cc-d0f8-4c6c-ae84-0c48d1f0b554` (`call_id=cll_06E39KQRPDSAZ0B88TX3ZN87T8`)
- `claim_id=330af21e-5c3a-40dc-909d-0d6b215ef91b` (`call_id=cll_06E748DBJDTX19FK8Q88ET00J4`)

## Risks and Guardrails
- Risk: text-derived due parsing can over-trigger.
  - Guardrail: store `due_confidence` and suppress low-confidence rows from paging paths.
- Risk: contact-phone matching can miss follow-ups (number changes/aliases).
  - Guardrail: prefer `contact_id` when present; use phone as fallback.
- Risk: duplicate alerts on repeated runs.
  - Guardrail: idempotency key per `(claim_id, due_at_utc)` and open-state uniqueness.

## Implementation Slice Recommendation
1. Ship read-only surface first (query/view + morning-brief integration field).
2. Add expectation/event tables once stakeholders validate precision.
3. Add closure hooks in `loop-closure` and/or morning brief runtime.
