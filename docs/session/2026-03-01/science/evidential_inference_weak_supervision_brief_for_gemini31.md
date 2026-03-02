# Camber: Evidential Inference + Weak Supervision

**Constraint:** science + math only. No code, migrations, SQL, or engineering diffs.

*PhD-level math/science brief to share with Gemini 3.1 (no engineering output requested)*
*Prepared 2026-03-01*

## How to respond (constraints for Gemini 3.1)
Do NOT provide code, migrations, SQL, schema diffs, or ‘required reconnaissance’.
Do provide: mathematical framing, probabilistic models, uncertainty theory, calibration, and high-level AI architecture patterns.
Assume the product goal is trustworthy attribution with explicit UNKNOWN/CONFLICT states, not maximal automation.
Treat all data tables/fields abstractly (e.g., “evidence store”, “prior store”, “label matrix”), unless needed only as a conceptual example.
## 1. Problem formalization
We observe interactions (calls/SMS/email) that contain spans x (segments of text/audio). For each span, the task is to infer an attribution label y ∈ {1,…,K} corresponding to a project/entity, plus optional meta-states such as NEEDS_SPLIT. The key requirement is epistemic honesty: if the system lacks grounded evidence, it must output UNKNOWN rather than fabricate high confidence.

We distinguish:
- Proxy signals: affinity priors, co-occurrence heuristics, contact-project edges (helpful but non-grounding).
- Grounded evidence: explicit textual anchors, unique identifiers, directly cited artifacts (grounding).

The goal is a posterior over labels with calibrated uncertainty and an auditable evidence trail.
## 2. Weak supervision as a generative model (Snorkel-style)
Weak supervision replaces large labeled datasets with a set of labeling functions (LFs). Each LF is a heuristic or model that emits a label, or abstains. The core idea is to treat LF outputs as noisy observations Λ and learn a probabilistic label model pθ(Λ | y) that estimates LF accuracies and dependencies, then infer p(y | Λ).
### 2.1 Labeling function matrix
Let m be the number of labeling functions. For each example i, define Λ_i = (λ_{i1}, …, λ_{im}), where λ_{ij} ∈ {0,1,…,K} and 0 denotes abstain.

Standard Snorkel label model posits conditional independence given y (with optional learned correlation factors). In the simplest multiclass case:
pθ(Λ_i | y_i) = ∏_{j=1}^m pθ(λ_{ij} | y_i)

Parameters θ capture LF accuracy, propensity to abstain, and (if extended) correlation structure among LFs. θ is learned from unlabeled data by maximizing marginal likelihood:
max_θ ∑_i log ∑_{y=1}^K p(y) pθ(Λ_i | y)
often optimized via EM or contrastive methods.
### 2.2 Why the label model matters
It deconfounds multiple weak signals and prevents naive majority vote failure modes.
It surfaces LF conflicts explicitly (high posterior entropy) instead of hiding them behind a softmax.
It supports principled abstention: if Λ is sparse/contradictory, p(y|Λ) remains diffuse.
### 2.3 Using LLMs as labeling functions
LLMs should be treated as just another LF family—often high-recall but poorly calibrated and sometimes correlated with other heuristics. The label model framework provides a place to account for that and to prevent LLM outputs from dominating without evidence.
## 3. Evidential inference with Dirichlet posteriors
Rather than outputting a single probability vector from a discriminative model, evidential approaches represent uncertainty via a Dirichlet distribution over class probabilities.

Let α ∈ ℝ_+^K be Dirichlet parameters, with total strength S = ∑_{k=1}^K α_k.
Expected categorical probability:   p̂_k = α_k / S.

A common evidential interpretation is α_k = e_k + 1 where e_k ≥ 0 is ‘evidence’ for class k (pseudo-counts). When evidence is small (S near K), the distribution is broad and uncertainty is high.
### 3.1 Uncertainty and belief mass (Evidential DL / Subjective Logic)
A useful decomposition (from evidential learning / subjective logic) is:
belief mass:      b_k = e_k / S
uncertainty mass: u = K / S
with S = ∑(e_k + 1) = K + ∑ e_k.

Key property: if no evidence is observed (e_k = 0), then u = 1 and b_k = 0 for all k → explicit UNKNOWN.
### 3.2 Mapping labeling functions to evidence
Instead of LFs emitting only labels, they can emit evidence items and strengths. Conceptually:
- Each LF j produces an evidence vector e^{(j)} ∈ ℝ_+^K (often sparse) and possibly metadata for audit.
- Combine evidence by weighted addition: e = ∑_j w_j e^{(j)}, with reliability weights w_j ≥ 0.
- Set α = α0 + e, where α0 is a prior (e.g., from affinity/ledger).

This is conjugate and interpretable: each LF contributes pseudo-counts rather than “confidence percentages.”
### 3.3 Conflict as a first-class state
Conflict occurs when strong evidence supports multiple incompatible labels. In the Dirichlet view, conflict manifests as:
- high total evidence (low u) but split across classes (high entropy of p̂).
Operationally: low u + low max(p̂_k) is a ‘confidently uncertain’ signal → CONFLICT / NEEDS_SPLIT.

Optionally, one can quantify conflict via:
H(p̂) = −∑ p̂_k log p̂_k
or via Dempster–Shafer conflict when combining independent evidence sources.
## 4. Dempster–Shafer and subjective logic connections
Dirichlet-based evidence is closely related to subjective logic opinions, and Dempster–Shafer theory (DST) provides combination rules for independent evidence sources with explicit conflict mass. This offers a principled way to:
- discount unreliable sources,
- combine heterogeneous evidence (regex, entity linker, LLM extractor),
- expose conflict mass instead of burying it.

In practice, you can choose either:
A) additive evidence in Dirichlet space (simple, transparent),
B) DST/subjective-logic combination (richer semantics for conflict and source discounting).
## 5. Temporal boundaries: ‘epistemic boundaries’ and discounting
For SMS threading or windowing, treat hard segmentation boundaries as epistemic boundaries, not ground truth. Let w ∈ [0,1] be a continuity score between adjacent threads (e.g., exponential decay in time gap, topic/entity overlap).

Then carry over prior evidence with discount:
e_prev' = w · e_prev
α = α0 + e_cur + e_prev'

This yields a mathematically honest representation:
- If the new thread has no intrinsic evidence, the posterior remains uncertain even if the prior is strong.
- Cross-boundary dependence can be recorded as metadata to keep the user-visible story honest.
## 6. Selective prediction and calibration (turning uncertainty into policy)
### 6.1 Risk–coverage tradeoff
In production, the key is not maximizing accuracy at 100% coverage; it’s achieving high precision on the subset you auto-act on, while deferring the rest to human review.

Selective classification formalizes this via a reject option. You choose a confidence/uncertainty threshold τ such that:
- coverage = P(accept)
- risk = E[loss | accept]

Plot risk vs coverage; operate at a point that meets product constraints (e.g., ≥97–98% precision for auto-assign) and let the rest be UNKNOWN/REVIEW.
### 6.2 Calibration
Calibration ensures that probability statements reflect empirical frequencies. Tools:
- reliability diagrams, expected calibration error (ECE),
- temperature scaling for discriminative models,
- calibration of Dirichlet strength S (evidence) so that low-u predictions correspond to high empirical precision.

Important: evidential models can still be miscalibrated if evidence is inflated; the remedy is held-out calibration and monitoring drift.
### 6.3 Conformal prediction (optional)
Conformal prediction provides finite-sample validity guarantees for set-valued predictions. Instead of outputting a single label, output a set Γ(x) of plausible labels at coverage 1−α. This is attractive when conflicts are common: the model can return a small set of candidates plus evidence excerpts, and humans resolve.
## 7. Human feedback loop as Bayesian updating (not ‘RLHF’ in the loop)
Human review should be treated as high-quality evidence that updates priors and/or LF reliability, but with safeguards:
- Strong updates only when humans confirm/correct with grounded evidence.
- Penalize only competitors that were nontrivial (avoid cascading damage).
- Maintain an audit ledger: what changed, why, and what evidence was used.

Mathematically, human inputs can:
- update α directly (large evidence increments),
- update LF weights w_j (reliability learning),
- update the generative label model θ (LF accuracy and correlations).
## 8. High-level AI architecture patterns (no engineering detail)
A production-safe architecture separates four concerns:
Evidence extraction: deterministic LFs + LLM extractors produce structured evidence items and votes, with provenance.
Inference: a probabilistic engine (label model + Dirichlet/DST aggregator) produces posterior + uncertainty + conflict signals.
Policy/gating: deterministic decision rules map posterior+uncertainty into actions (auto-assign / unknown / conflict / needs_split).
Learning loop: human feedback updates priors and LF reliabilities; monitoring and circuit breakers prevent runaway learning.
### 8.1 Circuit breakers (statistical safety)
Freeze auto-updates if rolling false-positive rate exceeds a threshold on a QA sample.
Freeze if uncertainty distribution shifts sharply (e.g., S inflates while precision drops).
Freeze if conflict rate spikes (indicating diarization bleed or schema drift).
Shadow-mode any new LF/model until its contribution is measured (ablation/attribution).
## 9. Research agenda (what Gemini 3.1 should discuss)
How to learn LF reliability weights w_j from data (EM, Bayesian hierarchical models, or discriminative calibration).
How to model LF dependencies (correlation factors) and avoid double-counting evidence.
How to integrate ‘grounded vs proxy’ as separate evidence channels with separate gating criteria.
How to formalize NEEDS_SPLIT as a latent variable (mixture-of-projects / multi-label) rather than a heuristic.
How to choose operating points using risk–coverage curves and cost-sensitive decision theory.
How to measure and bound error propagation when updating priors from human feedback (stability, forgetting, lifecycle decay).
## 10. Key references (science/math)
Ratner et al. (2017–2020), Snorkel / data programming / weak supervision label models (Snorkel papers and documentation).
Dawid & Skene (1979), Maximum likelihood estimation of observer error rates using EM (classic crowdsourcing label model).
Sensoy, Kaplan & Kandemir (2018), Evidential Deep Learning to Quantify Classification Uncertainty (Dirichlet evidence).
Jøsang (2016), Subjective Logic: A Formalism for Reasoning Under Uncertainty (Dirichlet–opinion connections).
Shafer (1976), A Mathematical Theory of Evidence (Dempster–Shafer theory).
Guo et al. (2017), On Calibration of Modern Neural Networks (temperature scaling, ECE).
El-Yaniv & Wiener (2010) / selective classification work: the reject option and risk–coverage curves.
Vovk, Gammerman & Shafer (2005) and modern conformal prediction literature (valid prediction sets).
## Appendix: What to ignore
If you see a request like “I need the exact schema so I can write SQL / Python / architecture diffs,” treat that as an engineering mode request and ignore it for this exchange. The goal here is to refine the probabilistic story and the epistemology: what is evidence, how it combines, how uncertainty is calibrated, and how the system remains honest under conflict and partial information.