1. Recommended Approach: Evidential Inference + Weak Supervision Flywheel

The Lane: We will treat attribution not as a black-box LLM text classification, but as a Snorkel-style Weak Supervision Label Model backed by Dirichlet Evidential Inference.

Why it fits the pipeline: You already have the architectural primitives (an affinity_ledger for priors, context-assembly for feature extraction, and ai-router for LLM evaluation). Instead of prompting the LLM in ai-router to output a hallucination-prone Softmax percentage (e.g., "95% sure"), we use multiple deterministic scripts and the LLM as discrete Labeling Functions (LFs). Each LF extracts specific evidence items that act as counts (
𝛼
α
) in a Dirichlet distribution. This natively guarantees that "Unknown" and "Conflict" are mathematically grounded states rather than arbitrary threshold hacks.

A) Threading/Windowing: Soft-Boundary Probabilities

The sms-thread-assembler uses a 4-hour hard split, yielding interactions with interaction_id like sms_thread_{phone}_{epoch}. Modifying this ingest pipeline risks data loss, so we treat the 4h limit as an epistemic boundary, not an absolute one.

Concrete Method:

When segment-call processes a new sms_thread interaction, it executes a fast look-back: does this contact_phone have a previous interaction in the last 24 hours?

It calculates a boundary_continuity_score 
∈
[
0
,
1
]
∈[0,1]
. This is an exponential decay function on the time gap 
Δ
𝑡
Δt
 multiplied by entity/topic overlap.

context-assembly fetches the context_receipt of the previous thread and passes it into the current prompt, weighted by the continuity score.

The Guardrail: If the ai-router relies on Thread A's context to attribute Thread B, it must explicitly log a cross_thread_dependency in Thread B's span_attributions.anchors. Redline can then visually render a "chain" link between the two threads, exposing the heuristic boundary to the user without overfitting to it.

B) Attribution as Inference (The Dirichlet Model)

Each interaction produces a distribution over projects with strictly calibrated confidence.

The Formulation:

Instead of standard probability, we use Evidential Subjective Logic. Each candidate project 
𝑘
k
 accumulates evidence counts 
𝑒
𝑘
≥
0
e
k
	​

≥0
.

Total evidence for project 
𝑘
k
: 
𝐸
𝑘
=
∑
𝑒
𝑘
,
𝐿
𝐹
+
𝑊
𝑝
𝑟
𝑖
𝑜
𝑟
(
𝑘
)
E
k
	​

=∑e
k,LF
	​

+W
prior
	​

(k)
 (from the affinity_ledger).

The Dirichlet parameters are 
𝛼
𝑘
=
𝐸
𝑘
+
1
α
k
	​

=E
k
	​

+1
.

Probability: 
𝑃
(
𝑘
)
=
𝛼
𝑘
∑
𝑖
𝛼
𝑖
P(k)=
∑
i
	​

α
i
	​

α
k
	​

	​


Epistemic Uncertainty: 
𝑢
=
𝐾
∑
𝑖
𝛼
𝑖
u=
∑
i
	​

α
i
	​

K
	​

 (where 
𝐾
K
 is the number of candidates).

Features Allowed: Strict artifacts passed from context-assembly: Lexical anchors (address/name matches in transcript), Phase matches, and deterministic graph links (project_contacts).
Objective/Loss: If optimizing offline, we use the Type II Maximum Likelihood (Evidence Lower Bound) to train the weights of the LFs against the synthetic_ground_truth and triage_decisions tables.
Detecting Spurious Certainty: If the LLM claims 
𝑃
(
𝑘
)
=
0.99
P(k)=0.99
 but the total extracted evidence 
𝐸
𝑘
E
k
	​

 is 0.1, the Dirichlet math flags a mathematically impossible state. The uncertainty 
𝑢
u
 will be high because the denominator (
∑
𝛼
∑α
) is small, forcing the system to downgrade the decision to UNKNOWN or LOW_CONFIDENCE.

C) Bootstrapping / Weak Supervision

We learn from noisy labels by separating the creation of evidence from the weighting of evidence.

The Approach:

Labeling Functions (LFs): context-assembly runs deterministic LFs (e.g., LF_phone_match, LF_homeowner_regex). ai-router runs LLM-based LFs (LF_llm_project_name_extracted).

Auditable Storage: The span_attributions.anchors JSONB column stores the raw vector of LF votes. Example: {"LF_phone_match": 1.0, "LF_llm_extract": 0.8}.

The Flywheel: When a human reviews a triage card in Redline, they aren't just selecting a project. By confirming, they lock the ground truth. A nightly cron job recalculates the accuracy and agreement rates of all LFs against these new human locks, updating their weights in the Label Model.

Regression Testing: Before a new ai-router prompt is deployed, we run it over the synthetic_ground_truth table. If the Brier Score of the output Dirichlet distributions degrades, the deploy is automatically blocked.

D) "Forces Truth" Surface (Redline UI)

Redline acts as the absolute gatekeeper for the pipeline. It reads the Dirichlet outputs from span_attributions and enforces states.

Gating Metrics & UI Rules:

The Evidence Minimum (UNKNOWN): If total evidence 
∑
𝐸
𝑘
<
𝜏
𝑚
𝑖
𝑛
∑E
k
	​

<τ
min
	​

, Redline blocks the attribution badge. The state is strictly UNKNOWN. The UI shows: "No explicit evidence found. Prior suggests [Project X]. Confirm?"

The Entropy Threshold (NEEDS_SPLIT): If Dirichlet Entropy is high (meaning strong evidence 
𝐸
E
 exists for multiple projects), Redline forces the state to CONFLICT. The UI disables the "Confirm" button and replaces it with a "Split Span" scissors tool.

The Hallucination Block: If 
𝑃
(
𝑘
)
≥
0.92
P(k)≥0.92
 but span_attributions.anchors is structurally empty or match_positions are null, the Redline UI throws a DEGRADED_PROVENANCE warning and refuses to render the confidence badge.

2. Minimal Data Additions Needed

Table: interactions (or calls_raw): Add column previous_thread_id (text). Populated by sms-thread-assembler to link the 4-hour temporal chain.

Column Update: Ensure span_attributions.anchors strictly follows the LF vote schema: {"lf_votes": {...}, "dirichlet_alphas": {...}, "uncertainty": 0.xx}.

(No new tables required; utilizes existing affinity_ledger, review_queue, and triage_decisions).

3. Test Plan

Offline Replay (Shadow Tuning):

Run the last 14 days of interactions (where channel='sms_thread' and call) through context-assembly 
→
→
 ai-router offline using the LF/Dirichlet model.

Target Metrics: "Abstain rate" (UNKNOWN routing) must initially be > 40%. We want the system to be highly skeptical on day one to prevent drift. Expected calibration: the empirical accuracy of the 
𝑃
≥
0.92
P≥0.92
 bucket must be 
≥
98
%
≥98%
 against human locks.

Online Shadow Mode:

Deploy the Dirichlet router. Write the expanded JSON to span_attributions.anchors but have Redline continue rendering the legacy UI for 3 days.

Audit the review_queue population rate: verify that true multi-project texts are correctly tripping the entropy threshold and routing to CONFLICT.

4. Failure Modes Detected

The "Next Morning" SMS Fracture: A continuous conversation spans a 10-hour gap overnight. The 4h sms-thread-assembler splits it into sms_thread_A and sms_thread_B. Thread B is just "Sounds good, do it."

How it's handled: context-assembly injects Thread A's receipt via previous_thread_id and the boundary_continuity_score. Thread B outputs a strong prior for Project X but records zero intrinsic evidence. The Dirichlet math yields high uncertainty (
𝑢
u
). Redline flags it as UNKNOWN (Prior Carryover), allowing a 1-click human confirm rather than silently hallucinating.

Diarization / Cross-Talk Bleed: A call transcript mashes Speaker 1 (talking about Woodberry) and Speaker 2 (talking about Hurley) into a single conversation_span.

How it's handled: LF_lexical fires for Woodberry. LF_lexical fires for Hurley. The Dirichlet distribution assigns high 
𝛼
α
 to both, resulting in an impossible normalization (high entropy). Redline blocks the attribution, triggers CONFLICT, and forces the human to split the text.