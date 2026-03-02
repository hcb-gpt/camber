# Session Retirement Epistemology

## Executive summary

Session retirement epistemology is the discipline of **turning an ephemeral agent session into a durable, verifiable knowledge artifact** that a successor (human or agent) can trust, audit, and resume from. It combines the structure of high-stakes human handoffs (healthcare, watchstanding, mission control), the rigor of operational logging and lessons-learned systems, and the safety properties of distributed systems (idempotent shutdown, durable logs, lineage). The key novelty versus traditional handoffs is that the “receiver” may be a **stateless compute process** with limited context and unreliable implicit memory, so correctness must rely on **structured artifacts + provenance + verification steps** rather than shared tacit context.

Across domains, successful handoffs converge on a few invariants: (i) a **standardized narrative frame** (e.g., SBAR, I-PASS), (ii) a **chronological log** with governance and signatures (deck logs; mission control console logs), (iii) a **checklist and walkdown** to validate current state, (iv) a **receiver synthesis/readback**, and (v) a place to capture **lessons learned** and disseminate them. Healthcare formalizes this with SBAR’s four-part communication scaffold and I-PASS’s receiver synthesis component. citeturn15view0turn6search3turn13view0

For ephemeral agents, these invariants must be strengthened with machine-friendly properties: **evidence contracts**, strict **provenance fields** (run IDs, commit SHAs, artifact hashes), **access controls** (RLS), and **procedural verification** that can be executed (or replayed) automatically. Distributed-systems shutdown semantics provide a direct analogy: Kubernetes lifecycle hooks are “at least once,” must be lightweight, and may be killed if they exceed a grace period—meaning retirement must be **idempotent**, safe to retry, and designed for partial completion. citeturn17view3

This memo recommends a concrete five-section retirement protocol, plus a storage schema (JSON + SQL DDL), templates, metrics, and rollout guidance. The protocol is designed to be immediately usable as a TRAM-uploadable file and to support VP review.

## Prior art survey

Healthcare handoffs: SBAR and I-PASS  
SBAR offers a compact, universally remembered structure for urgent handoffs: Situation, Background, Assessment, Recommendation. The Institute for Healthcare Improvement frames SBAR as an “easy-to-remember” mechanism that sets expectations for what and how information is communicated, and documents its Kaiser Permanente provenance (Leonard, Bonacum, Graham). citeturn15view0 This is valuable for agents because it optimizes for “scannability,” reducing cognitive load for the receiver.

I-PASS is a more comprehensive, evidence-based handoff bundle and curriculum. The I-PASS mnemonic explicitly includes **“Synthesis by receiver,”** formalizing that correct handoff requires the receiver to restate understanding. citeturn6search3turn13view0 The I-PASS curriculum work emphasizes standardized processes, adoption as a transformational change effort, and monitoring/assessment tools (including observation and feedback loops). citeturn13view0 These map cleanly to agent retirement: standardized sections, enforced gates, and “receiver ack” as an explicit protocol step.

Military watch turnover: logs, checklists, legal standing  
Watchstanding doctrine treats the log as authoritative and legally consequential. A U.S. DoD watchstanding guide describes the ship’s deck log as a complete daily record, with **historical importance and legal standing**, potentially used in courts; entries cannot be erased and must be signed (end-of-watch signature). citeturn17view1 This is a strong precedent for treating a retirement artifact as a governed record, not a casual note.

A contemporary U.S. Navy command instruction requires that prior to being relieved, the off-going watchstander turns over with the on-coming watch, and that the on-coming duty officer ensures a **turnover checklist** is completed and filed. It also references a BLUF-style log/report practice. citeturn17view0 The checklist + filing mechanism translates directly to a machine-enforced “artifact completeness” gate.

Aerospace operations and mission control: console logs and shift handover reports  
NASA mission control tooling highlights an explicit division between (a) a chronological console log and (b) a structured shift handover report that provides event-, anomaly-, and issue-oriented views, constructed by sorting log entries into report categories and then adding explanatory context. citeturn7view2 This is a precise prior art match for agent retirement: maintain an append-only event log, then generate a structured handoff summary with pointers back to source events. The same NASA report explicitly frames placing “knowledge in the world” (interface/log) rather than “knowledge in the head,” reinforcing artifact-first continuity. citeturn7view2

Nuclear and high-reliability operations: walkdowns, controlled turnover, fitness, signed responsibility transfer  
DOE’s operations turnover standard is unusually explicit about attention control, verification, and formal acceptance. It recommends an accompanying **walkdown** so the on-coming operator can ask questions and verify station status with immediate feedback. citeturn10view1L186-L190 It also recommends limiting access into control areas during information exchange so personnel remain focused. citeturn10view1L420-L425 The standard emphasizes that checklists should **point to existing information**, not duplicate it, and that checklist items are updated throughout the shift to capture evolving conditions. citeturn10view1L304-L308L335-L338

Critically, DOE ties the transfer to readiness and documentation: the off-going person assesses the on-coming person’s physical/mental state, the on-coming person signifies assumption of responsibility, and the transfer is documented with a log entry; the off-going person does not leave until acceptance occurs. citeturn10view1L444-L458 This translates to an agent-world “receiver synthesis + acceptance signature,” including explicit uncertainty if acceptance is partial.

Knowledge management and after-action reviews: learning loops and dissemination  
Army doctrine defines an after-action review (AAR) as a guided analysis with the objective of improving future performance, emphasizing professional discussion, self-discovery, and a non-blaming climate. citeturn19view0L4-L13 It also specifies organizing observations chronologically and producing after-action reports/lessons learned that are retained, reviewed, and shared. citeturn19view0L167-L173L262-L270

NASA institutionalizes knowledge capture at policy level: NPD 7120.6A mandates cultivating, capturing, retaining, sharing knowledge; highlights the Lessons Learned Information System (LLIS) as a principal mechanism; and explicitly frames mitigation of attrition/program closeouts as a knowledge-loss risk. citeturn7view5L25-L35 This is directly aligned with “session retirement” as an attrition analog for ephemeral agents.

Distributed systems: graceful shutdown, durable logs, replay  
Distributed systems prioritize correctness under interruption. Kubernetes lifecycle hooks clarify that PreStop hooks run before termination signals, can hang, may be killed after a grace period, and have **at-least-once delivery**, requiring idempotent implementations; long-running hooks are appropriate only when saving state before stop. citeturn17view3 Postgres explains write-ahead logging (WAL) as a durability mechanism: replaying log entries restores consistency after crashes. citeturn17view4 These provide a rigorous analogy: the retirement artifact should be replayable, and retirement generation should be safe under partial completion and retries.

Agent memory and reflection literature: why retirement is necessary  
LLM agents are constrained by context windows; MemGPT proposes “virtual context management” inspired by OS memory tiers to extend context and enable multi-session chat with persistent memory. citeturn7view3 Reflexion shows agents improving by storing reflective text in an episodic memory buffer based on feedback, rather than updating weights—an explicit “trial-to-trial” knowledge carryover mechanism. citeturn7view4 Modern surveys argue that “long/short-term” is insufficient; new taxonomies examine agent memory by form (token/parametric/latent), function (factual/experiential/working), and dynamics (formation/evolution/retrieval), explicitly foregrounding trustworthiness issues. citeturn20view1

Production memory tooling (Mem0, Letta) operationalizes multi-level memory and persistence; Mem0 emphasizes user/session/agent state and latency/token advantages, while Letta positions stateful agents with governance features such as RBAC. citeturn20view3turn20view4 Evaluation work like LoCoMo constructs long-horizon multi-session dialogue benchmarks to measure very long-term memory and grounding—useful for retirement evaluation design. citeturn20view2

## Theoretical framing

Definition and scope  
Session retirement epistemology is the **theory and practice of converting a session’s internal state and knowledge claims into an externalized, governed record** such that (a) a successor can reconstitute operational context with minimal ambiguity, and (b) claims are graded by evidential support and can be independently verified. Unlike “logging” or “summarization,” retirement epistemology explicitly answers: *What is known? What is merely believed? What is unknown? What would change my mind?*

Goals  
A retirement protocol should (i) preserve continuity of intent, tasks, and decisions; (ii) minimize successor time-to-orientation; (iii) make claims auditable by linking to sources of truth (issues, commits, receipts, dashboards, query results); (iv) prevent unsafe knowledge transfer (secrets, cross-tenant data); and (v) enable organizational learning (patterns, countermeasures).

Constraints distinguishing ephemeral-agent handoffs from human handoffs  
Humans share tacit context, can ask clarifying questions, and can detect nonsense via common sense and social accountability. Ephemeral agents cannot reliably rely on implicit memory; they may “hallucinate coherence,” silently drop context, or lose tool state. The handoff must therefore be (a) **artifact-first**, (b) **machine-readable**, and (c) **verifiable by replay**.

Success criteria  
A practical success envelope includes: rehydration time (minutes to regain working context), completeness (no critical open loop missing), verifiability (high-trust claims traceable to evidence), safety (no secret leakage; access control intact), and robustness (idempotent retirement generation; safe retries).

Failure modes  
Common failures include omission (forgotten open loops), ambiguity (unclear owners/next steps), contradiction (inconsistent state snapshots), staleness (snapshot doesn’t match live reality), and unverifiable claims (“it’s fixed” without proof). Agent-specific failures add hallucinated state, tool/queue drift, cross-session identity confusion, and non-idempotent retirement that produces conflicting artifacts when retried. The Kubernetes “at least once” hook guarantee is a useful mental model: any retirement step may run twice. citeturn17view3

## Gap analysis

Existing handoff practices are strong on structure and discipline, but they under-specify four requirements that become mandatory for ephemeral agents.

Verifiability and provenance  
Deck logs and mission control logs are authoritative, but most human handoffs tolerate unverifiable assertions because the receiver can interrogate the sender. Agents need explicit provenance: links/IDs/hashes that allow independent validation, echoing DOE’s advice to use checklists as pointers to existing authoritative information rather than duplicating content. citeturn10view1L304-L308turn7view2

Receiver synthesis as a formal gate  
I-PASS and DOE both embed receiver-side confirmation (synthesis; documented acceptance), but many modern engineering handoffs treat this as optional. Agents require it as a gate, because otherwise the successor may proceed with misinterpreted context. citeturn6search3turn10view1L444-L458

Automation-compatible structure  
SBAR/I-PASS provide mnemonics for humans, but they do not define machine-validated schemas, minimum required fields, or retry-safe workflows. Kubernetes explicitly forces idempotency; retirement protocols should too. citeturn17view3turn15view0

Security and scope control  
Human logs assume professional discipline; agent retirement must be guarded by default with role-based access and row-level controls because artifacts accumulate sensitive references over time. PostgreSQL’s CREATE POLICY/RLS model provides a concrete enforcement substrate. citeturn6search1

## Recommended five-section protocol and artifacts

Protocol design principles distilled from prior art  
The protocol below combines: SBAR-style scannability citeturn15view0, I-PASS receiver synthesis citeturn6search3, DOE walkdown + signed transfer citeturn10view1L186-L190turn10view1L444-L458, NASA log→report generation citeturn7view2, and distributed-systems idempotent shutdown semantics citeturn17view3turn17view4.

Comparison table: human handoff vs agent retirement needs  

| Dimension | Mature human practice | What changes for ephemeral agents |
|---|---|---|
| Structure | SBAR/I-PASS mnemonics reduce omission | Must be schema-validated (required fields, controlled vocab) |
| Logs | Deck logs / console logs are authoritative records citeturn17view1turn7view2 | Logs must be linkable (IDs), replayable, and hashable (immutability) |
| Verification | Walkdowns and checklists validate current station state citeturn10view1L186-L190 | Verification steps should be automatable and recorded as proofs |
| Acceptance | Receiver synthesis/readback, signed transfer citeturn6search3turn10view1L444-L458 | Must be a gate; no “retired” state without receiver ACK |
| Learning | AARs + lessons learned repositories citeturn19view0turn7view5 | Lessons should be structured, searchable, and linked to incidents/receipts |
| Robustness | Humans adapt when interrupted | Must be idempotent and retry-safe (at-least-once semantics) citeturn17view3 |

Mermaid flowchart of the five-section retirement protocol

```mermaid
flowchart TD
  A[Retirement Trigger] --> B[Freeze inbound work\nmark session as DRAINING]
  B --> C[Generate State Snapshot\nqueues, tasks, toggles, deployments]
  C --> D[Assemble 5-section Artifact\nwith evidence links + provenance]
  D --> E[Run Verification Checklist\n(auto + receiver)]
  E --> F{Receiver Synthesis + ACK?}
  F -->|No| G[Status: PARTIAL\nlists blockers + retry plan]
  F -->|Yes| H[Seal + Archive\nwrite hashes + set RETIRED]
  H --> I[Publish Lessons Learned\n+ update indices]
```

Five sections and required artifacts  
Each section should be short, but must contain pointers to authoritative sources (receipts, issue IDs, commits), matching DOE’s “pointers not duplication” doctrine. citeturn10view1L304-L308

Section one: Identity and scope  
Required: session_id, role, start/end timestamps, retirement reason (planned/forced), scope boundaries, successor identity, and “what this session was responsible for.”

Section two: Current situation snapshot  
Required: the minimal operational snapshot needed to resume: open work items, queue depths, active incidents, recent changes. Include “what is stable vs volatile,” echoing DOE’s emphasis on performing turnover when conditions are stable. citeturn10view1L420-L423

Section three: Claims and evidence contract  
Represent each major claim as a tuple: {claim, confidence, evidence links}. Treat this as the agent equivalent of the log’s legal standing mindset: the record must be specific and correctable without erasure (append corrections). citeturn17view1

Section four: Unknowns, risks, and watchlist  
Include explicit unknowns and triggers. This is the antidote to “spurious certainty,” aligning with agent-memory research emphasizing trustworthiness issues. citeturn20view1

Section five: Receiver synthesis and acceptance  
A required receiver readback (human or agent), plus explicit acceptance state: ACCEPTED / ACCEPTED_WITH_EXCEPTIONS / REJECTED. This is the strongest single upgrade drawn from I-PASS and DOE. citeturn6search3turn10view1L444-L458

Sample retirement file template (Markdown)

```markdown
# Session Retirement: <session_id>

## Identity and scope
- Role: <STRAT|DEV|DATA|...>
- Start / End (UTC): <...> / <...>
- Retirement reason: <planned|context_limit|handoff|failure|other>
- Scope owned: <explicit bullets, bounded>
- Successor: <session_id or person>
- Links: TRAM thread(s): <ids>; Repo/PR(s): <links>; Dashboard(s): <links>

## Situation snapshot
- Active incidents: <incident_ids + status>
- Open work items (top 10): <id | owner | priority | next action | due>
- Queues/backlogs: <queue_name: depth, oldest_age, SLA>
- Last changes: <commit_sha(s) + what changed + rollback notes>
- Operational invariants: <what must remain true>

## Claims and evidence
Each claim MUST include a verification pointer.
1) Claim: ...
   - Confidence: <high|med|low>
   - Evidence: <receipt/issue/SQL/hash/screenshot link(s)>
   - Counterfactual: <what would disprove it>
2) ...

## Unknowns, risks, watchlist
- Unknowns: <explicit>
- Risks: <impact + likelihood + mitigation>
- Watchlist triggers: <metrics/alerts thresholds>
- Anti-goals / do-not-do: <to avoid regression>

## Receiver synthesis and acceptance
- Receiver summary (readback):
  <what receiver believes is true>
- Acceptance state: <ACCEPTED|ACCEPTED_WITH_EXCEPTIONS|REJECTED>
- Exceptions / missing artifacts:
  <list>
- Verification checklist run:
  - [ ] links resolved
  - [ ] snapshot validated
  - [ ] secrets scan passed
  - [ ] RLS/permissions verified
- Sign-off: <name/session_id> @ <timestamp>
```

Sample concise TRAM memo (paste-ready)

```text
SUBJECT: retirement__<session_id>__<YYYYMMDD>
STATUS: DRAINING→RETIRED (pending receiver ACK)

1) Scope: <what was owned> | Boundaries: <what was NOT owned>
2) Snapshot: incidents=<n>; open_items=<n>; queue_depths=<...>
3) Claims (w/ evidence): <top 3 claims + receipts/links>
4) Unknowns/risks: <top 3> | Watchlist: <metrics/alerts>
5) Receiver synthesis required: please readback + set ACCEPTED/REJECTED.
Artifact: <link to retirement markdown + hash>
```

Sample blog-post framing (short)

```markdown
Title: “When Agents Die: A Discipline for Verifiable Handoffs”
Thesis: Human handoffs (SBAR, I-PASS, watch logs, mission control) succeed because they force structure, verification, and receiver readback. Ephemeral agents need the same—but strengthened with provenance, machine-verifiable evidence, and idempotent shutdown semantics.
Outline:
- Why summaries fail: tacit context and unverifiable claims
- The five invariants across high-reliability domains
- Session Retirement Epistemology: definition + success criteria
- The five-section protocol (with example)
- What changes in production: evidence contracts, RLS, lineage, canaries
```

JSON schema sketch for a retirement artifact store  
This schema supports provenance, evidence links, and receiver acceptance.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "SessionRetirement",
  "type": "object",
  "required": ["retirement_id", "session_id", "role", "started_at", "ended_at", "status", "snapshot", "claims", "receiver_ack", "provenance"],
  "properties": {
    "retirement_id": {"type": "string", "format": "uuid"},
    "session_id": {"type": "string"},
    "role": {"type": "string"},
    "status": {"type": "string", "enum": ["DRAINING", "PARTIAL", "RETIRED"]},
    "started_at": {"type": "string", "format": "date-time"},
    "ended_at": {"type": "string", "format": "date-time"},
    "scope": {"type": "object"},
    "snapshot": {"type": "object"},
    "claims": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["claim", "confidence", "evidence_refs"],
        "properties": {
          "claim": {"type": "string"},
          "confidence": {"type": "string", "enum": ["high", "med", "low"]},
          "evidence_refs": {"type": "array", "items": {"type": "string"}},
          "counterfactual": {"type": "string"}
        }
      }
    },
    "receiver_ack": {
      "type": "object",
      "required": ["state", "readback", "acked_at"],
      "properties": {
        "state": {"type": "string", "enum": ["ACCEPTED", "ACCEPTED_WITH_EXCEPTIONS", "REJECTED"]},
        "readback": {"type": "string"},
        "exceptions": {"type": "array", "items": {"type": "string"}},
        "acked_at": {"type": "string", "format": "date-time"}
      }
    },
    "provenance": {
      "type": "object",
      "required": ["code_commit", "run_id", "artifact_hash"],
      "properties": {
        "code_commit": {"type": "string"},
        "run_id": {"type": "string", "format": "uuid"},
        "artifact_hash": {"type": "string"},
        "lineage": {"type": "object"}
      }
    }
  }
}
```

SQL DDL for storage with provenance and RLS hooks  
Use an append-only pattern for audit-grade records (deck-log analog). PostgreSQL RLS policies can enforce scope-based access. citeturn6search1

```sql
create table if not exists session_retirements (
  retirement_id        uuid primary key default gen_random_uuid(),
  session_id           text not null,
  role                 text not null,
  started_at           timestamptz not null,
  ended_at             timestamptz not null,
  status               text not null check (status in ('DRAINING','PARTIAL','RETIRED')),

  artifact_md_url      text null,
  artifact_hash        text not null,               -- sha256 of canonical artifact bytes
  snapshot_json        jsonb not null,
  claims_json          jsonb not null,
  receiver_ack_json    jsonb not null,
  provenance_json      jsonb not null,

  created_at           timestamptz not null default now()
);

create index if not exists idx_session_retirements_session
  on session_retirements (session_id, created_at desc);

create index if not exists idx_session_retirements_status
  on session_retirements (status, created_at desc);

create index if not exists idx_session_retirements_claims_gin
  on session_retirements using gin (claims_json);

-- RLS is optional but recommended for multi-tenant or sensitive operations.
alter table session_retirements enable row level security;

-- Example policy outline (replace predicate with org-specific membership checks).
-- create policy "read_retirements_for_members"
-- on session_retirements for select
-- using ( exists (select 1 from membership where membership.user_id = auth.uid()) );
```

Example TRAM receipt text (minimal, auditable)

```text
kind: status_update
to: STRAT
from: <ROLE>
subject: retirement__<session_id>__<YYYYMMDD>
ack_andon: yes
content:
  status: RETIRED (or PARTIAL)
  artifact_hash: sha256:<...>
  artifact_link: <...>
  receiver_ack: <ACCEPTED|...> by <session_id/person> at <timestamp>
  top_claims:
    - <claim> | evidence: <receipt/issue/commit>
```

## Implementation guidance, evaluation metrics, and rollout

Tooling and controls  
Use a two-layer approach: (i) an artifact generator that writes the five sections and computes a content hash, and (ii) an automated validator that checks required fields, resolves referenced receipts/links, and enforces “no RETIRED without receiver ACK.” This mirrors DOE’s focus on checklists and documented transfer. citeturn10view1L444-L458 A lineage facet can be emitted using OpenLineage-style event models (job/run/dataset) to capture what inputs produced the retirement artifact. citeturn6search0

Reproducible experiments  
A minimal experimental design is to simulate forced session termination and measure successor recovery. Inspired by LoCoMo’s multi-session evaluation framing, create a benchmark suite of “handoff tasks” (resume an incident, continue a backlog triage, reproduce a deployment state) with ground-truth completion criteria. citeturn20view2 Compare: (a) free-form summaries, (b) five-section protocol without evidence, (c) five-section protocol with evidence + receiver ack gate.

Metrics  
Track: time-to-orientation (first correct action), open-loop recall (missed critical items), claim verifiability rate (claims with resolvable evidence), correction rate (post-handoff contradictions), safety compliance (secret scan/RLS violations), and retry robustness (duplicate retirements produce identical hash or are safely versioned). Kubernetes’ “at least once” hook behavior is a good stress model: intentionally run retirement twice and ensure no semantic drift. citeturn17view3

Rollout and canary  
Start with shadow-mode retirements (generate artifacts but do not enforce gates), then add a canary where “RETIRED requires receiver ACK” for a subset of sessions, then ratchet toward full enforcement. Align incentives with SRE practice: shift transitions require reading the previous handoff and sending a handoff message at end of shift. citeturn21view0

## Sources

```text
Healthcare handoffs
- IHI SBAR Tool (origin + definition): https://www.ihi.org/library/tools/sbar-tool-situation-background-assessment-recommendation
- I-PASS mnemonic (includes “Synthesis by receiver”): https://www.ipassinstitute.com/hubfs/I-PASS-mnemonic.pdf
- I-PASS curriculum development paper (Starmer et al., Acad Med 2014 PDF): https://www.ipassinstitute.com/hubfs/I-Pass_Dec20/Evidence/Starmer-et-al-Acad-Med-2014-Development-of-I-PASS.pdf

Military watch turnover / logs
- Navy watch instruction with turnover checklist requirement (NAVSUPPACTNAPLESINST 1601.4J PDF): https://cnreurafcent.cnic.navy.mil/Portals/78/NSA_Naples/Documents/NSA%20Naples%20Instructions/NAVSUPPACTNAPLESINST%201601_4J%20COMMAND%20WATCH%20ORGANIZATION%20AND%20STANDING%20ORDERS.pdf
- DoD watchstanding guide noting deck log legal standing (PDF): https://media.defense.gov/2014/Feb/21/2002655425/-1/-1/1/140221-N-ZZ182-5350.pdf

Aerospace shift handoffs
- NASA NTRS D-Logger / shift handover report paper (PDF): https://ntrs.nasa.gov/api/citations/20060009030/downloads/20060009030.pdf

Nuclear/high-reliability turnover
- DOE-STD-1038-93 operations turnover (UNT PDF mirror): https://digital.library.unt.edu/ark:/67531/metadc683338/m2/1/high_res_d/296701.pdf

Knowledge management / learning loops
- U.S. Army FM 7-0 Appendix K After Action Reviews (PDF): https://www.first.army.mil/Portals/102/FM%207-0%20Appendix%20K.pdf
- NASA NPD 7120.6A Knowledge Policy for Programs and Projects: https://nodis3.gsfc.nasa.gov/displayDir.cfm?c=7120&s=6&t=NPD

Distributed systems analogs
- Kubernetes container lifecycle hooks (PreStop, at-least-once semantics): https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- PostgreSQL WAL and crash recovery (PITR docs): https://www.postgresql.org/docs/current/continuous-archiving.html

Agent memory / reflection
- Reflexion (arXiv): https://arxiv.org/abs/2303.11366
- MemGPT (arXiv): https://arxiv.org/abs/2310.08560
- Mem0 repo (universal memory layer): https://github.com/mem0ai/mem0
- Letta docs (stateful agents, RBAC): https://docs.letta.com/
- Memory taxonomy survey (arXiv 2512.13564): https://arxiv.org/abs/2512.13564
- LoCoMo benchmark paper (ACL 2024): https://aclanthology.org/2024.acl-long.747/

Governance and access control
- PostgreSQL CREATE POLICY / RLS: https://www.postgresql.org/docs/current/sql-createpolicy.html
- OpenLineage object model: https://openlineage.io/docs/spec/object-model/
```