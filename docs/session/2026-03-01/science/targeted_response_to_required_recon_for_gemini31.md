# Response to “Required Reconnaissance” (science + math only)

Prepared: 2026-03-01

**Purpose:** This note is meant to be forwarded to **Gemini 3.1** as a targeted response to the “REQUIRED RECONNAISSANCE” request. The key constraint: **we do not want code, SQL, migrations, or engineering diffs**. We want **math/science**: probabilistic modeling, uncertainty theory, calibration, and high-level AI architecture principles.

Source prompt: fileciteturn57file0

---

## Hard constraint (please follow)

Gemini 3.1: **Do not ask for schemas, endpoints, or deployment state in order to proceed**, and do not return code blocks.  
Instead, treat unknown implementation details as **latent variables** and provide a scientifically grounded plan that remains valid across implementations.

If you need “inputs,” ask only for **abstract statistics** (counts, rates, distributions) and describe **why** they matter mathematically (e.g., “LF coverage distribution,” “LF pairwise agreement matrix,” “reviewer access to evidence: yes/no”).

---

## What your 4 “recon” items translate to scientifically

### Recon 1: “LF Overlap Matrix” (schema request)
**Engineering framing:** “Give me exact table schemas so I can write phone/regex labeling functions.”  
**Scientific reframing:** “We need a **generative model of weak supervision** with **dependent, abstaining annotators**, and we need to understand the **geometry of the labeling function outputs** (coverage, conflicts, dependencies).

What we want from you (math/science deliverable):
1) **Formal model choices** for LF aggregation:
   - Dawid–Skene / EM for annotators, multiclass extensions.
   - Snorkel-style label model with dependency factors.
   - Bayesian variants (hierarchical priors over LF accuracy / abstain propensity).
2) **How to use an overlap matrix** without knowing any schema:
   - Define Lambda in [0..K]^(n x m) as the LF label matrix (0=abstain).
   - Define pairwise overlap/agree statistics:  
     overlap(j,k)=P(lambda_j!=0 AND lambda_k!=0), agree(j,k)=P(lambda_j=lambda_k | both fire).
   - Discuss how to detect LF dependence using mutual information / correlation factors.
3) **Identifiability limits and what breaks them** (the “no free lunch” part):
   - When do you need any gold labels at all?
   - What minimal supervision (small audited set) is required to calibrate?
4) **LF weighting** without code:
   - Provide theory for learning reliability weights w_j (EM, Bayesian updating, isotonic/temperature calibration at the decision layer).
5) **Grounded vs proxy evidence as separate channels**:
   - Propose a two-channel model where grounded evidence must be non-empty for “auto-assign,” while proxy evidence can only promote candidates into “review.”

What we explicitly do **not** want:
- A request for column names.
- Instructions to write deterministic functions.
- “Pull this SQL.”

### Recon 2: “Review Swarm State” (does runner read anchors vs transcript?)
**Engineering framing:** “Tell me what the runner reads so it won’t hallucinate.”  
**Scientific reframing:** “We need a **two-stage epistemic system**: (a) evidence extraction and (b) evidence adjudication, with strong guarantees that adjudication is **constrained by evidence** rather than free-form generation.”

What we want from you:
1) **Epistemology of auditing**: how a “reviewer” should behave when evidence is absent or conflicting.
   - Define admissibility: a claim is admissible only if it cites at least one grounded evidence item.
   - Define three outcomes: CONFIRM / REJECT / UNKNOWN (plus optional NEEDS_SPLIT).
2) **Mathematical interface contract** (no code):
   - Inputs: candidate set, evidence set E (grounded/proxy), priors pi, and a reviewer policy.
   - Outputs: posterior q(y), uncertainty u, and a cited evidence bundle.
3) **Uncertainty-aware review**:
   - Use a Dirichlet/subjective-logic view: evidence mass yields (belief, uncertainty) where zero evidence -> u≈1 -> UNKNOWN.
   - Discuss conflict metrics: high total evidence but split mass -> CONFLICT/NEEDS_SPLIT.
4) **How to prevent “second-opinion hallucination”**:
   - Reviewer must not introduce new facts; it can only (i) select among existing evidence, (ii) declare missing evidence, (iii) request human input.
   - Provide scientific justification: constrained inference reduces false certainty, improves calibration, and makes QA measurable.

What we do **not** want:
- “Tell me whether function X reads column Y.”
- Architecture diffs.
- Implementation steps.

### Recon 3: “Atomic RPC deployment” (are atomic_claim_work/atomic_ack_message merged?)
**Engineering framing:** “Confirm deployment so dispatching agents is safe.”  
**Scientific reframing:** “We need a **distributed-systems correctness story** for multi-agent orchestration: idempotency, exactly-once semantics (or the best achievable approximation), and failure-mode containment.”

What we want from you:
1) **Correctness model** (no infra specifics):
   - Define desired properties: linearizability vs eventual consistency, safety vs liveness, at-least-once delivery, idempotent ack.
2) **Claim/ack as a consensus/locking primitive**:
   - Compare: leasing, CAS, transactional outbox patterns, and queue semantics.
3) **Risk analysis**:
   - What are the mathematically relevant failure modes? (duplicate work, dropped acks, split-brain ownership, delayed visibility)
4) **How to validate correctness scientifically**:
   - Propose invariants and metrics: “no two owners for one claim,” “ack rate vs timeout rate,” “collision probability under load,” “mean time to repair.”

What we do **not** want:
- “Go check if it deployed.”
- SQL migrations to create RPCs.

### Recon 4: “Codex anomaly / taxonomy enforcement” (UUID session IDs leaking)
**Engineering framing:** “Tell me what is in operator_sessions so FOR_SESSION routing works.”  
**Scientific reframing:** “This is an **addressability and routing** problem: naming schemes define a keyspace; routing requires stable keys and aliasing under migration.”

What we want from you:
1) **Formalize routing as a function**:
   - A mapping R(message) -> destination that depends on a session identifier.
   - Explain how inconsistent key generation (UUID leaks) causes silent routing failure (messages become unaddressable).
2) **Migration theory**:
   - How to maintain continuity during renames: alias maps, versioned namespaces, backward-compatible routing rules.
3) **Reliability metrics**:
   - Probability of misroute, message loss under partial adoption, and detection strategies (e.g., “unmatched FOR_SESSION rate”).

What we do **not** want:
- A request to inspect the DB trigger.
- Engineering steps to “fix the trigger.”

---

## The actual deliverable we want from Gemini 3.1

Please produce a **math/science memo** with these sections:

1) **Weak Supervision Model**  
   - Formal label model, dependence modeling, identifiability, and what statistics we need (abstractly).

2) **Evidential Inference**  
   - Dirichlet/subjective logic/Dempster–Shafer framing; how evidence maps to belief+uncertainty; conflict definition; abstention policy.

3) **Calibration + Selective Prediction**  
   - Risk–coverage tradeoff, operating point selection, conformal prediction (optional), and how to avoid “confidence theater.”

4) **Human Feedback as Bayesian Updating**  
   - Safe update operators for priors (stability, discounting, lifecycle-aware decay), with circuit breakers.

5) **High-level Architecture Principles** (not implementation)  
   - Separation of evidence extraction vs adjudication; auditability; constraints that prevent hallucination; and monitoring metrics/invariants.

Appendix: list of key references (Snorkel/weak supervision; Dawid–Skene; evidential deep learning; subjective logic; calibration; selective classification; conformal prediction).

---

## Minimal “stats-only” questions you *may* ask (optional)

If you truly need inputs, restrict yourself to asking for **abstract aggregates**, not schemas:

- LF coverage distribution per LF (how often each LF fires vs abstains).
- LF pairwise overlap/agree matrix summary (top correlated pairs).
- Review outcomes distribution (CONFIRM/REJECT/UNKNOWN) over time.
- Auto-assign precision at different confidence thresholds (risk–coverage curve points).
- Distribution of evidence mass (Dirichlet strength S) for “high confidence” claims (to detect confidence inflation).
- Thread boundary gap distribution (for continuity discounting models).

Anything beyond that drags us into engineering, which is explicitly out of scope for this exchange.

---

## Bottom line

We want you to help us **decide the correct math** for:
- combining weak signals without double-counting,
- representing uncertainty honestly (UNKNOWN/CONFLICT as first-class),
- selecting safe action thresholds with calibration,
- and designing an auditable learning loop that doesn’t run away.

No code. No schema recon. No migrations.
