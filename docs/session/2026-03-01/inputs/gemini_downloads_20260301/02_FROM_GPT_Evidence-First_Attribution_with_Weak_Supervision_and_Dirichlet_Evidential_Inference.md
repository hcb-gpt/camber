# Evidence-First Attribution with Weak Supervision and Dirichlet Evidential Inference

## Executive summary

Evidence-first attribution aims to produce **auditable, uncertainty-aware** project assignments (or labels) for conversational spans: every high-confidence attribution must be backed by **explicit evidence artifacts** (matched excerpts, entity links, rule firings), while low-evidence situations must resolve to **UNKNOWN/ABSTAIN** rather than “confident guesses.” This report synthesizes the core math of Dirichlet-based evidential inference, Snorkel-style weak supervision, and production AI architecture patterns into a rigorous blueprint suitable for PhD-level discussion.

A practical “best-of-both-worlds” approach is to use **weak supervision labeling functions (LFs)** to extract discrete, inspectable evidence signals and combine them with a **Bayesian evidential layer** (Dirichlet/Dirichlet-multinomial) that separates (i) *what label is most likely* from (ii) *how much epistemic support exists*. This mirrors how evidential deep learning represents predictions as **Dirichlet distributions over class probabilities** instead of single softmax points. citeturn0search0turn0search4

At a systems level, the winning production pattern is a **hybrid pipeline**: deterministic + LLM-based LFs → label model aggregation → evidential scorer (Dirichlet posterior + calibrated abstention) → optional downstream discriminative model trained on probabilistic labels. This is essentially the Snorkel data programming paradigm, which learns LF accuracies (and potentially dependencies) without dense ground truth labels and uses them to generate probabilistic training labels. citeturn0search2turn0search18turn2search18

Because probability estimates must be trustworthy to drive routing (AUTO vs REVIEW vs UNKNOWN), calibration must be treated as first-class: temperature scaling is a surprisingly strong post-hoc calibrator for modern neural nets, while proper scoring rules (log loss, Brier score) provide principled evaluation. citeturn0search3turn0search7turn5search1turn5search13

**Dimension coverage map**

| Requested dimension | Where covered |
|---|---|
| Core math: Dirichlet/DM, Bayesian updating, UQ, calibration, alternatives | Core math and uncertainty for evidence-first attribution |
| Weak supervision: LFs, label model math, noise-aware aggregation, design patterns, limits | Weak supervision with labeling functions and label models |
| Evidence contracts/data model: anchors/span_attributions schema, LF votes/alphas/provenance, auditability/RLS | Evidence contracts and data model |
| AI architectures: hybrid pipelines, scalable inference, streaming/batch, shadow mode, circuit breakers, deployment | Production architectures and deployment patterns |
| Evaluation & tests: metrics, calibration plots, stress tests, regressions, rollout | Evaluation, testing, and rollout strategies |
| Practical tradeoffs: latency/compute, data needs, failure modes, HITL, governance | Practical tradeoffs, governance, and implementation guidance |
| Implementation guidance: libraries, papers, 3-horizon roadmap, reproducible experiments | Practical tradeoffs, governance, and implementation guidance |
| Sources: primary papers + links | References |

## Core math and uncertainty for evidence-first attribution

This section covers the requested core math: **Dirichlet models, Dirichlet-multinomial, Bayesian updating, uncertainty quantification, calibration**, and major alternatives.

### Dirichlet as a distribution over categorical probabilities

For a K-class attribution problem, we model the unknown class-probability vector **p** on the simplex with a Dirichlet distribution:

\[
\mathbf{p} \sim \text{Dir}(\boldsymbol{\alpha}),\quad \boldsymbol{\alpha}=(\alpha_1,\ldots,\alpha_K),\ \alpha_k>0
\]

Key moments:

\[
\mathbb{E}[p_k] = \frac{\alpha_k}{\alpha_0},\quad \alpha_0=\sum_{i=1}^K \alpha_i
\]

\[
\text{Var}(p_k)=\frac{\alpha_k(\alpha_0-\alpha_k)}{\alpha_0^2(\alpha_0+1)}
\]

The parameter **α₀** (total concentration) controls epistemic certainty: **large α₀ → peaked distribution (more certainty)**; **small α₀ → diffuse distribution (more uncertainty)**. This is classical Bayesian conjugacy for categorical/multinomial likelihoods. citeturn4search8turn4search12turn4search0

### Dirichlet–multinomial conjugacy and Bayesian updating as “evidence accumulation”

If we observe class-count evidence **n = (n₁,…,n_K)** (e.g., counts of supporting cues or LF firings), and the likelihood is multinomial/categorical, the Dirichlet prior updates additively:

\[
\boldsymbol{\alpha}^{\text{post}} = \boldsymbol{\alpha}^{\text{prior}} + \mathbf{n}
\]

This additive update makes Dirichlet ideal for evidence-first systems, because each evidence event can be interpreted as a **pseudo-count** (possibly fractional) that increments α for a candidate project/class. citeturn4search8turn4search0

A common engineering parameterization is:

\[
\alpha_k = 1 + e_k,\quad e_k\ge 0
\]

where **e_k** is “evidence mass” supporting class k. This is consistent with evidential deep learning, which learns nonnegative evidence outputs that parameterize a Dirichlet distribution over class probabilities. citeturn0search0turn0search4

### Uncertainty quantification from Dirichlet parameters

Evidence-first routing needs an explicit uncertainty signal. With Dirichlet, several uncertainty proxies are available:

**Concentration-based epistemic uncertainty.** In subjective-logic/evidential formulations, a simple uncertainty mass is often tied to concentration: lower α₀ implies higher uncertainty. Sensoy et al. frame this within subjective logic and Dirichlet-based opinions. citeturn0search0turn0search8turn2search7

**Entropy of the predictive mean.** Compute the entropy of \( \mathbb{E}[\mathbf{p}] \):

\[
H(\mathbb{E}[\mathbf{p}]) = -\sum_k \mathbb{E}[p_k]\log \mathbb{E}[p_k]
\]

This captures “confusion” among top projects but does not fully distinguish epistemic vs aleatoric uncertainty.

**Expected entropy / mutual information (Bayesian active learning style).** If you treat Dirichlet as a posterior over class probabilities, you can compute (or approximate) expected entropy and information measures; Prior Networks were motivated partly by the need to distinguish different uncertainty sources (data vs distributional mismatch) using distributions over predictive distributions. citeturn0search1turn0search5

### Evidential deep learning and prior networks as “single-pass” distributions over distributions

Two influential “Dirichlet-output” deep approaches:

**Evidential Deep Learning (EDL).** Replace softmax outputs with Dirichlet parameters derived from evidence learned by a deterministic network; prediction is a Dirichlet distribution rather than a point. citeturn0search0turn0search4

**Prior Networks.** Train a network to output a **Dirichlet prior** over categorical distributions, designed explicitly to model **distributional uncertainty** and improve OOD detection relative to methods that conflate sources of uncertainty. citeturn0search1turn0search5turn0search13

Surveys unify and compare these families (prior/posterior networks, EDL variants), highlighting both strengths and pitfalls. citeturn9search1turn9search20

Critically, recent work argues that many EDL methods may provide **poor epistemic uncertainty** in asymptotic regimes (e.g., uncertainties not vanishing with infinite data), and that observed wins may be better interpreted as energy-based OOD behavior rather than faithful Bayesian epistemics. citeturn10view0  
For evidence-first attribution, this pushes toward a pragmatic stance: **use Dirichlet primarily as an interpretable evidence ledger** (LF- and cue-derived α updates), and treat EDL-style learned evidence as optional, heavily validated augmentation.

### Calibration: making probabilities and abstention thresholds trustworthy

Calibration is mandatory if you route work based on confidence. Modern neural nets are often miscalibrated, and temperature scaling is a simple, effective post-hoc fix across datasets and architectures. citeturn0search3turn0search7

Recommended evaluation uses:

**Log loss / negative log likelihood** (a strictly proper scoring rule). Proper scoring rules incentivize honest probabilities; Gneiting & Raftery’s survey is a canonical reference. citeturn5search1

**Brier score** (mean squared error over probability vectors), originally proposed for probabilistic forecasts; it is also a proper scoring rule in common classification settings and is widely used in forecasting and ML calibration analysis. citeturn5search13turn5search1

**Expected Calibration Error (ECE)** via reliability diagrams is widely used but has known estimator issues (binning sensitivity), leading to improved estimators and kernel-smoothed variants in recent literature. citeturn5search12turn5search31turn5search4

### Alternatives to Dirichlet for uncertainty

Evidence-first attribution can use alternatives (often complementary) to Dirichlet:

**Bayesian neural nets (variational).** Bayes by Backprop learns distributions over weights to represent uncertainty. citeturn1search2turn1search6

**MC Dropout.** Interprets dropout as approximate Bayesian inference, enabling uncertainty estimates from multiple stochastic forward passes. citeturn1search1turn1search5

**Deep ensembles.** A practical, scalable baseline: train multiple models with different initializations; often yields strong uncertainty and calibration, and scales to large datasets (including ImageNet). citeturn1search0turn1search4

**Conformal prediction.** Wrap any model to produce prediction sets with distribution-free coverage guarantees (under exchangeability), useful for producing *top-k candidate sets* and principled abstention. citeturn2search0turn2search8

**Selective classification / reject option.** Optimize a classifier that abstains to meet a target risk level, yielding explicit risk–coverage tradeoffs. citeturn2search1turn2search5

### Comparison table: Dirichlet vs Bayesian NNs vs evidential nets vs ensembles

| Method | What it outputs | Key math object | Strength for evidence-first | Main weaknesses | Typical production use |
|---|---|---|---|---|---|
| Dirichlet evidence accumulator | Posterior over class-prob vector | Dir(α), α update by counts | Directly maps inspectable evidence → α; easy auditing; natural UNKNOWN | Needs careful calibration of evidence weights; can be gamed by correlated evidence | “Evidence ledger” + routing gate; often paired with LF extraction |
| Evidential deep learning | Dirichlet from NN evidence | Dir(α(x)) learned by special loss | Single-pass uncertainty; aligns with subjective logic framing citeturn0search0turn2search7 | Some methods’ epistemic uncertainty may be unreliable; requires strong validation citeturn10view0 | Optional enhancement; best as calibrated signal, not sole gate |
| Prior networks | Dirichlet prior/posterior | Dirichlet prior over categoricals | Explicitly targets distributional uncertainty / OOD separation citeturn0search1turn0search5 | More specialized training; still needs calibration and monitoring | OOD-aware gating for “unknown domain / new project” |
| Bayesian NN (VI) | Distribution over weights → predictive distribution | Variational posterior over weights | Principled Bayesian story; handles epistemic uncertainty | Harder training; computational overhead; approximation quality | Higher-stakes workflows; where Bayesian tooling maturity exists citeturn1search2 |
| MC Dropout | Empirical distribution from multiple passes | Approx Bayesian GP view | Easy retrofit to existing nets citeturn1search1turn1search5 | Slower inference (many passes); can under-estimate uncertainty under shift | Online introspection + uncertainty heuristics |
| Deep ensembles | Mixture of predictors | Ensemble predictive distribution | Strong baseline; good calibration; parallelizable citeturn1search0turn1search4 | Compute/storage cost; complexity of managing multiple models | Default production uncertainty baseline, esp. if compute is available |

## Weak supervision with labeling functions and label models

This section covers the requested weak supervision dimension: **Snorkel-style LFs, label model math, noise-aware aggregation, conflict/abstain, LF design patterns, and theoretical limits.**

### Data programming and the Snorkel paradigm

Weak supervision shifts the interface from “label data point by point” to “write heuristics that label many points,” with a probabilistic model that denoises conflicting sources. This is the core idea of data programming and Snorkel. citeturn0search18turn0search2

Snorkel’s end-to-end pipeline is typically:

1) users write labeling functions (LFs) that emit noisy labels or abstain,  
2) a generative label model learns LF accuracies (and sometimes dependencies) without ground truth, producing probabilistic labels,  
3) a downstream discriminative model is trained on these probabilistic labels. citeturn0search2turn2search18

### Label model math at a high level

Let \(Y\) be an unobserved true label and \(\lambda_j(X)\) be LF outputs (including abstain). Snorkel’s LabelModel is described as learning conditional probabilities of LF outputs given the latent true label, \(P(\lambda \mid Y)\), and using them to reweight and combine LF votes into probabilistic labels. citeturn2search18

In a simplified conditional-independence label model, the likelihood factorizes:

\[
P(\lambda_1,\ldots,\lambda_m \mid Y) \approx \prod_{j=1}^m P(\lambda_j \mid Y)
\]

and parameters can be learned by maximizing the marginal likelihood over unlabeled data:

\[
\max_{\theta}\sum_{i}\log \sum_{y} P_{\theta}(y)\prod_{j} P_{\theta}(\lambda_{ij} \mid y)
\]

Real systems often relax independence by adding dependency factors (or by learning structure), because correlated LFs can otherwise inflate confidence.

### Conflict, overlap, and abstain handling

Abstain is first class: LFs commonly output a special abstain value, and the label model uses LF coverage, overlaps, and conflicts to understand which sources are informative. Snorkel provides built-in analysis utilities describing conflicts as cases where an LF’s label disagrees with at least one other non-abstaining LF. citeturn3search7turn3search25

### LF design patterns for evidence-first attribution

Evidence-first attribution wants LFs that are **explicitly auditable**. Common LF patterns in Snorkel deployments include heuristic patterns/regexes, dictionary/ontology matches, external KB lookups, and model-based weak labelers; Snorkel explicitly frames LFs as a wrapper for “patterns, heuristics, external knowledge bases, and more.” citeturn0search2turn0search10

For production evidence contracts, prioritize:

- **High-precision “anchor” LFs**: fire only when evidence is strong (exact alias match, phone/email identity match, explicit address mention). These should strongly contribute to α when they fire.
- **Proxy LFs**: weaker signals like historical affinity or recency; these must be stored and surfaced as proxy evidence, never masquerading as grounded evidence.
- **Negative/anti-LFs**: explicitly suppress candidates when strong contradicting evidence appears (e.g., “mentions Project B alias” is negative evidence against Project A).
- **Context-window LFs**: handle threading boundaries by explicitly representing cross-thread dependence in provenance (avoid silent context carryover).

Continuous or quality-guided LFs (real-valued votes) are an active research direction; for example, continuous/quality-guided labeling functions can encode graded evidence strengths rather than hard labels. citeturn3search1

### Theoretical limits and identifiability

Weak supervision is powerful but not magic: identifiability depends on assumptions about LF accuracies and dependencies. Snorkel research explicitly focuses on learning LF dependency structure without labeled data because incorrect dependency modeling can degrade inferred labels. citeturn2search6turn2search25

Modern weak supervision work also provides theory on scaling with unlabeled data under certain conditions; data programming papers argue that, with appropriate LF conditions, generalization can scale similarly to supervised learning but depends on unlabeled data size. citeturn3search23turn0search18

Multi-task weak supervision extends this to settings where sources label different granularities/tasks; matrix-completion style formulations are used to recover accuracies given dependency structure, again highlighting that dependency modeling is central. citeturn3search0turn3search8

## Evidence contracts and data model

This section covers the requested evidence-contract dimension: **schema for anchors/span_attributions, storing LF votes and Dirichlet α, uncertainty, provenance, query patterns, auditability, and RLS considerations.**

### Why evidence contracts matter scientifically

Evidence-first systems should avoid the trap where “explanations” are persuasive but unfaithful. In NLP, attention weights are often not faithful explanations, and rationale work emphasizes extracting *supporting evidence spans* rather than relying on opaque internal weights. citeturn13search0turn13search2turn13search4  
Benchmarks like ERASER formalize evaluation of rationales (evidence snippets) and their faithfulness/alignment. citeturn13search2turn13search14

Therefore, the data model should store **evidence excerpts and provenance** as primary artifacts, not just probability numbers.

### Recommended schema pattern: typed columns + JSONB “anchors” with references

A strong production compromise is:

- keep **typed columns** for filtering/sorting (state, top label, confidence, uncertainty, entropy, timestamps),
- keep **JSONB anchors** for extensible evidence payloads and LF vote vectors,
- optionally normalize **evidence_events** into a separate table and store references in anchors for immutable audit trails.

PostgreSQL JSONB is flexible, but predictable performance requires indexing (GIN) aligned to query patterns. citeturn8search2turn8search22

### Sample `span_attributions` schema and anchors contract

Below is a sample DDL. Adapt naming to your environment (projects, cases, entities, spans).

```sql
-- Core per-span attribution record
create table if not exists span_attributions (
  span_id                 uuid primary key,
  interaction_id          uuid not null,
  span_index              int  not null,

  -- Candidate set (optional but useful for audits)
  candidate_ids           uuid[] not null,

  -- Primary outputs
  top_candidate_id        uuid null,
  decision_state          text not null check (decision_state in
                           ('AUTO', 'REVIEW', 'UNKNOWN', 'CONFLICT', 'NEEDS_SPLIT')),

  -- Dirichlet evidence model (store both mean + α for auditability)
  posterior_mean          jsonb not null,      -- {candidate_uuid: prob}
  dirichlet_alpha         jsonb not null,      -- {candidate_uuid: alpha}

  -- Typed uncertainty signals for routing
  alpha0                  numeric not null,    -- sum α_k
  uncertainty_mass        numeric not null,    -- e.g., function(alpha0)
  predictive_entropy      numeric not null,    -- H(E[p])
  evidence_support_gap    numeric not null,    -- e.g., grounded vs proxy gap

  -- Evidence contract container
  anchors                 jsonb not null default '{}'::jsonb,

  model_version           text not null,
  pipeline_run_id         uuid not null,
  created_at              timestamptz not null default now()
);

-- Typical indexes: state filtering + JSON evidence queries
create index if not exists idx_span_attr_state_created
  on span_attributions (decision_state, created_at desc);

create index if not exists idx_span_attr_anchors_gin
  on span_attributions using gin (anchors);
```

Recommended `anchors` JSON contract:

```json
{
  "grounded_evidence": [
    {
      "evidence_id": "uuid",
      "cue_type": "project_alias|address|phone|invoice|permit_id|speaker_self_id",
      "excerpt": "…Woodberry…",
      "span_ref": {"span_id":"uuid","start_tok":123,"end_tok":130},
      "source": {"channel":"sms|call_transcript","doc_id":"uuid"},
      "quality": {"exact_match": true, "confidence": 1.0}
    }
  ],
  "proxy_evidence": [
    {
      "cue_type": "affinity|recency|calendar_context",
      "weight": 0.42,
      "provenance": {"table":"affinity_ledger","row_id":"uuid"}
    }
  ],
  "lf_votes": {
    "LF_alias_exact": {"label":"<candidate_uuid>", "weight": 1.0, "evidence_ids":["uuid"]},
    "LF_llm_extract": {"label":"<candidate_uuid>", "weight": 0.6, "evidence_ids":["uuid"]}
  },
  "dirichlet": {
    "alpha": {"<candidate_uuid>": 7.2, "<candidate_uuid>": 1.4},
    "alpha0": 8.6,
    "uncertainty_mass": 0.23
  },
  "provenance": {
    "model_version": "router@2026-03-01",
    "lf_bundle_version": "lf-pack@hash",
    "code_commit": "gitsha",
    "feature_versions": {"graph":"v12", "aliases":"v7"},
    "runtime": {"latency_ms": 38, "host":"score-svc-3"}
  }
}
```

**Key principle:** keep “grounded” evidence distinct from “proxy” evidence, so that routing rules can enforce: *AUTO requires grounded evidence present*, otherwise REVIEW/UNKNOWN.

### Query patterns for audits and UI rendering

Examples:

```sql
-- Find high-confidence AUTO decisions missing grounded evidence (should be impossible).
select span_id, decision_state, posterior_mean, anchors
from span_attributions
where decision_state = 'AUTO'
  and coalesce(jsonb_array_length(anchors->'grounded_evidence'), 0) = 0;

-- Find CONFLICT cases where top-2 probabilities are too close (needs split / human).
select span_id, posterior_mean, predictive_entropy
from span_attributions
where decision_state in ('CONFLICT','NEEDS_SPLIT')
order by predictive_entropy desc
limit 200;

-- Search for a specific LF firing across spans (requires GIN on anchors).
select span_id, anchors->'lf_votes'->'LF_alias_exact' as lf_payload
from span_attributions
where anchors->'lf_votes' ? 'LF_alias_exact';
```

### Auditability, lineage, and governance

For evidence-first attribution, provenance should be treated as a lineage graph. OpenLineage provides an open standard for emitting job/run/dataset lineage events and can be adapted to capture “which model version + features + evidence artifacts produced this attribution.” citeturn8search3turn8search27

### RLS and security considerations

If attributions touch multi-tenant or role-sensitive data, enforce authorization at the database layer:

- PostgreSQL supports row-level security (RLS) via policies. citeturn8search4turn8search0  
- Supabase specifically positions RLS as “defense in depth” tied to auth identities. citeturn8search1

Example policy template:

```sql
alter table span_attributions enable row level security;

create policy "read_spans_for_authorized_projects"
on span_attributions for select
using (
  -- replace with your own membership check
  exists (
    select 1
    from project_memberships pm
    where pm.user_id = auth.uid()
      and pm.project_id = any(candidate_ids)
  )
);
```

Policy syntax and semantics (“USING”/“WITH CHECK”) are documented in PostgreSQL’s CREATE POLICY reference. citeturn8search0

### Sample `incident_ledger` schema for evidence-first operations

An incident ledger is the operational counterpart to evidence contracts: when something violates the contract (e.g., synthetics contamination, missing grounded evidence, routing regression), you log it as an auditable artifact.

```sql
create table if not exists incident_ledger (
  incident_id         uuid primary key default gen_random_uuid(),
  created_at          timestamptz not null default now(),
  created_by          uuid null,

  severity            text not null check (severity in ('P0','P1','P2','P3')),
  status              text not null check (status in ('OPEN','MITIGATED','FIXED','WONTFIX')),

  category            text not null,   -- e.g. "SYNTHETICS_LEAK", "MISCALIBRATION", "RLS_BUG"
  surface             text not null,   -- e.g. "iOS_contact_list", "router", "review_queue"
  description         text not null,

  sample_span_ids     uuid[] null,
  sample_interaction_ids uuid[] null,

  suspected_cause     text null,
  fix_commit_sha      text null,
  proof_artifacts     jsonb not null default '{}'::jsonb,  -- links/hashes/screens
  owner               text null,

  updated_at          timestamptz not null default now()
);

create index if not exists idx_incident_status_sev
  on incident_ledger (status, severity, created_at desc);
```

For multi-tenant scenarios, apply RLS similarly (per-category visibility or per-project scope), using PostgreSQL row security primitives. citeturn8search4turn8search0

## Production architectures and deployment patterns

This section covers the requested architecture dimension: **hybrid pipelines, scalable inference, streaming vs batch, shadow mode, circuit breakers, and deployment patterns (microservices, feature stores, model registries).**

### Recommended hybrid pipeline: LFs → label model → Dirichlet scorer → downstream model

Snorkel’s canonical architecture already separates (i) weak labeling from (ii) end model training. citeturn0search2turn0search18  
Evidence-first attribution extends that separation by inserting an **evidential inference layer** that outputs Dirichlet parameters (α) and explicit uncertainty.

Mermaid flowchart:

```mermaid
flowchart LR
  A[Ingest: messages/calls] --> B[Segmentation: conversation spans]
  B --> C[Candidate generation: graph + retrieval]
  C --> D[Feature extraction for evidence]
  D --> E[Labeling Functions (LFs)\n- deterministic rules\n- LLM extractors as LFs]
  E --> F[Label Model\n(Snorkel-style)\nlearn LF accuracies/deps]
  F --> G[Dirichlet Evidential Scorer\nalpha = prior + evidence]
  G --> H{Router}
  H -->|AUTO| I[Write span_attributions\n+ anchors evidence]
  H -->|REVIEW/UNKNOWN/CONFLICT| J[Human-in-loop UI\nSplit/Confirm]
  J --> K[Human decisions\n(triage/locks)]
  K --> L[Feedback loop:\nLF metrics + calibration\n+ retraining datasets]
  L --> F
  L --> M[Downstream discriminative model\ntrained on probabilistic labels]
  M --> G
```

### Streaming vs batch execution

A robust production stance:

- **Online/streaming path**: low-latency scoring for new spans; may run a lightweight LF set + cached candidate generation; writes outputs with provenance for later audit.
- **Batch path**: nightly/periodic recomputation of LF metrics, label-model re-fitting, calibration fitting, and backfills; can be orchestrated via standard ML pipeline tooling. TFX is a production-scale ML platform reference emphasizing orchestration, validation, and serving components. citeturn6search5turn6search21turn6search1

### Feature stores and training–serving consistency

If you maintain evidence features (aliases, entity links, recency, affinity), training-serving skew becomes a major failure mode. Google’s “Rules of ML” discusses training-serving skew as a core production problem, and model monitoring products explicitly track skew/drift. citeturn7search15turn7search19turn7search3

Feature stores like Feast are designed to standardize feature definition and serve consistent features for training and online inference, including ingestion from batch and streaming sources. citeturn6search10turn6search6turn6search22

### Model registry, versioning, and reproducibility

A registry is non-negotiable when routing decisions can affect user-visible outcomes:

- MLflow provides experiment tracking and model packaging, and its Model Registry manages versioned lifecycle stages. citeturn6search19turn6search15

### Scalable serving and deployment patterns

Two common deployment shapes:

- **Microservice scoring**: a “score” service takes span + candidates + features, runs LFs/label model/Dirichlet scoring, returns posterior + anchors; this is easiest to observe and scale horizontally.
- **Serving frameworks**: BentoML and Seldon Core provide standardized model serving/deployment on common infrastructure (containers/Kubernetes), useful for scaling inference stacks. citeturn7search0turn7search5turn7search4turn7search1

### Shadow mode and circuit breakers

**Shadow mode**: write new posteriors/anchors to storage but do not change UI routing for a fixed window; compare outcomes offline and measure regression.

**Circuit breakers** should trip on:

- miscalibration (confidence buckets failing accuracy),
- spillover into AUTO without grounded evidence,
- sudden drift in feature distributions (skew/drift monitors). citeturn7search3turn7search31

Selective classification literature provides a conceptual basis: you can guarantee a target risk by rejecting (abstaining) more, producing a risk–coverage curve used as a control surface. citeturn2search1turn2search5

## Evaluation, testing, and rollout strategies

This section covers the requested evaluation dimension: **metrics, stress tests, regressions, rollout, and the specific charts requested.**

### Metrics suite

You need two coupled metric families:

**Prediction quality (conditional on not abstaining)**  
Precision/recall/F1 or task-specific accuracy, measured on spans with ground truth.

**Selectivity and uncertainty**  
Abstain rate (coverage), and risk–coverage curves (error vs coverage). Selective classification makes this explicit and offers ways to target a desired risk level. citeturn2search1turn2search5

**Calibration**  
- Negative log likelihood (proper scoring rule). citeturn5search1  
- Brier score (proper scoring rule; foundational reference). citeturn5search13turn5search1  
- Reliability diagrams + ECE, with awareness that ECE estimators can be flawed and improved by kernel smoothing. citeturn5search12turn5search31turn5search4  
- Temperature scaling baseline. citeturn0search3turn0search7

**Evidence faithfulness**  
If you extract evidence excerpts, evaluate against human rationale annotations when possible; ERASER provides datasets and metrics for rationale alignment and faithfulness. citeturn13search2turn13search14

### Stress tests (targeting known failure modes)

Two stress tests you explicitly requested map cleanly to evaluation design:

**SMS threading fracture / context boundary errors**  
Test cases where the follow-up message contains no intrinsic evidence (“sounds good”) and correct attribution depends on prior context. The system should produce high uncertainty (UNKNOWN) or explicit cross-thread dependence, not confident AUTO.

**Diarization bleed / multi-topic span contamination**  
Call transcripts where two topics/projects co-occur. Dirichlet mean may have high entropy and/or low margin; the correct behavior is CONFLICT/NEEDS_SPLIT, not a single confident project.

Public datasets for building analogous tests:

- AMI Meeting Corpus for multi-speaker meeting transcripts and diarization-like complexity. citeturn14search4turn14search12  
- Switchboard for conversational telephone speech (useful for noise, disfluencies, and turn-taking). citeturn14search1  
- MultiWOZ for multi-domain dialogue where domain switches can emulate “project switches.” citeturn14search2turn14search6

### Regression tests and CI gates

Recommended test layers:

- **Unit tests for LFs**: each LF has golden positive/negative examples and a documented failure mode.
- **Golden-set replay**: fixed evaluation set of spans (including adversarial boundary cases) re-scored on every change.
- **Calibration regression**: enforce that high-confidence buckets remain calibrated; post-hoc temperature scaling (or other) must be refit on a fixed calibration set. citeturn0search3
- **Evidence contract tests**: assert that AUTO decisions contain at least one grounded_evidence item; fail fast otherwise.

### Evaluation charts (examples)

Reliability diagram template (synthetic example image to illustrate format):

![Reliability diagram (synthetic example)](sandbox:/mnt/data/reliability_diagram_synthetic.png)

Risk–coverage curve template (synthetic example image to illustrate selective-abstain behavior):

![Risk–coverage curve (synthetic example)](sandbox:/mnt/data/risk_coverage_curve_synthetic.png)

For real deployments, generate these from your stored `posterior_mean`, `decision_state`, and ground truth locks.

### Rollout strategy

A robust rollout sequence:

1) Offline replay on recent spans + synthetic adversarial cases (thread fracture, diarization bleed).  
2) Shadow mode: write outputs + anchors, do not change routing.  
3) Canary: enable AUTO for a small slice only when grounded evidence exists; route everything else to REVIEW/UNKNOWN.  
4) Expand only when calibration and risk–coverage targets remain stable under monitoring. Selective classification theory provides the language to describe and control this trade. citeturn2search1  
5) Consider conformal prediction to produce top-k candidate sets with coverage guarantees as an additional safety layer. citeturn2search0turn2search8

## Practical tradeoffs, governance, and implementation guidance

This section covers the requested tradeoff/governance dimension and provides the requested implementation guidance: **libraries, roadmap horizons, reproducible experiments.**

### Practical tradeoffs

**Latency vs evidence richness.**  
Deterministic LFs and graph lookups can be low latency; LLM-based evidence extraction can be expensive. A common pattern is a fast path (cheap LFs) plus async enrichment (LLM LFs) that may revise UNKNOWN/REVIEW cases later.

**Compute vs uncertainty quality.**  
Deep ensembles and MC dropout can yield strong uncertainty estimates but increase inference cost (ensembles require multiple models; MC dropout requires multiple passes). citeturn1search0turn1search1  
Dirichlet evidence accumulation is cheap and interpretable, but its quality depends on LF design and weight calibration.

**Data requirements.**  
Weak supervision reduces the need for dense labels, but evaluation and calibration still require a trusted labeled set. Snorkel’s research emphasizes learning from unlabeled data plus SME heuristics, but production confidence thresholds should be validated against a gold set. citeturn0search2turn0search18

**Failure modes.**  
- Correlated LFs can inflate confidence unless dependencies are modeled or structure is learned. citeturn2search6turn3search5  
- Proxy evidence masquerading as grounded evidence causes “spurious certainty.”  
- Distribution shift can break calibration; monitoring for skew/drift is required. citeturn7search3turn7search15  
- For EDL-style learned evidence, epistemic uncertainty reliability is an active concern; treat as “useful signal, not proof,” unless validated very carefully. citeturn10view0turn9search1

### Human-in-the-loop workflows

Evidence-first UI should prioritize **showing the exact supporting excerpt** (rationale) rather than a persuasive natural-language “explanation.” Rationale research provides formal treatment of evidence snippets, and attention-based explanations can be misleading. citeturn13search0turn13search2

Human actions should feed back into:

- LF performance dashboards (coverage/conflict/accuracy),
- calibration tuning,
- retraining datasets for the downstream discriminative model.

### Libraries and tooling recommendations

Weak supervision:
- **Snorkel** open-source LabelModel + LF analysis tools. citeturn2search18turn3search7turn3search25

Uncertainty and calibration:
- Temperature scaling baseline. citeturn0search3  
- Use proper scoring rules (NLL, Brier) and calibration diagnostics grounded in scoring-rule theory. citeturn5search1turn5search13  
- Consider conformal prediction tooling (many implementations accompany Angelopoulos & Bates). citeturn2search0turn2search4

Evidential/Dirichlet modeling:
- EDL reference implementation patterns exist in open repositories; treat them as starting points, not authority. citeturn0search24turn9search30  
- For conceptual grounding, subjective logic references are central. citeturn2search7turn2search3

MLOps / pipelines:
- TFX as production-scale platform reference; Google’s MLOps architecture guidance for CI/CD/CT. citeturn6search5turn6search1turn6search21  
- Feature store: Feast and its design motivations. citeturn6search10turn6search6  
- Model registry: MLflow paper and Model Registry docs. citeturn6search19turn6search15

Serving:
- BentoML and Seldon Core as practical serving frameworks. citeturn7search0turn7search5

Security/audit:
- PostgreSQL RLS + Supabase RLS docs for row-level enforcement. citeturn8search0turn8search1turn8search4  
- PostgreSQL GIN indexing guidance for JSONB-heavy anchors. citeturn8search2turn8search22  
- OpenLineage for lineage/provenance emission. citeturn8search3turn8search27

### Prioritized three-horizon roadmap

**Near-term horizon**  
Implement evidence contracts and weak supervision foundations:
- Define the anchors schema (grounded vs proxy evidence; LF vote vectors; α and uncertainty fields).
- Build a first LF pack (high-precision anchors first) and a Snorkel label model baseline. citeturn0search2turn2search18  
- Establish calibration + selective-abstain gates (risk–coverage targets). citeturn2search1turn0search3

**Mid-term horizon**  
Harden production-scale learning and monitoring:
- Add structure learning or dependency controls if LF correlation inflates confidence. citeturn2search6turn3search5  
- Train a downstream discriminative model on probabilistic labels; calibrate it (temperature scaling) and compare to ensembles. citeturn0search3turn1search0  
- Add drift/skew monitoring and circuit breakers. citeturn7search3turn7search15

**Long-term horizon**  
Extend to distribution shift robustness and stronger UQ guarantees:
- Consider Prior Networks for distributional uncertainty and/or conformal prediction for guaranteed candidate sets. citeturn0search1turn2search0  
- If adopting EDL, do so only with rigorous ablations, calibration checks, and awareness of critiques regarding epistemic reliability. citeturn10view0turn9search1  
- Standardize lineage across data/features/models with OpenLineage-style instrumentation. citeturn8search27turn8search3

### Reproducible experiments and datasets

Suggested experiment families:

- **Evidence extraction faithfulness**: use ERASER datasets/metrics for rationale alignment; compare LF-extracted evidence vs model-generated rationales. citeturn13search2turn13search14  
- **Thread fracture analog**: create synthetic “follow-up with no evidence” sequences in MultiWOZ-like dialogues where the last turn is ambiguous without context. citeturn14search2  
- **Diarization bleed analog**: mix transcript segments from different AMI sessions to create multi-topic spans; measure whether CONFLICT/NEEDS_SPLIT triggers appropriately. citeturn14search4turn14search12  
- **Uncertainty benchmarking**: compare Dirichlet evidence accumulator vs MC dropout vs deep ensembles for calibration and OOD detection (prior networks literature provides evaluation framing for uncertainty source separation). citeturn0search1turn1search0turn1search1

## References

Primary evidential/Dirichlet uncertainty:
- Sensoy, Kaplan, Kandemir. “Evidential Deep Learning to Quantify Classification Uncertainty.” citeturn0search0turn0search4  
- Malinin, Gales. “Predictive Uncertainty Estimation via Prior Networks.” citeturn0search1turn0search5  
- Ulmer, Hardmeier, Frellsen. “Prior and Posterior Networks: A Survey on Evidential Deep Learning Methods for Uncertainty Estimation.” citeturn9search1turn9search20  
- Shen et al. “Are Uncertainty Quantification Capabilities of Evidential Deep Learning a Mirage?” citeturn10view0  
- Jøsang. “Subjective Logic: A Formalism for Reasoning Under Uncertainty.” citeturn2search7turn2search3  
- Dirichlet-multinomial lecture notes (conjugacy, updates). citeturn4search8turn4search12turn4search0  

Calibration and scoring rules:
- Guo et al. “On Calibration of Modern Neural Networks.” citeturn0search3turn0search7  
- Gneiting, Raftery. “Strictly Proper Scoring Rules, Prediction, and Estimation.” citeturn5search1turn5search16  
- Brier. “Verification of Forecasts Expressed in Terms of Probability.” citeturn5search13turn5search2  
- “Measuring Calibration in Deep Learning” (ECE pitfalls and measurement critique). citeturn5search12  
- “Smooth ECE: Principled Reliability Diagrams via Kernel Smoothing.” citeturn5search31  

Uncertainty alternatives:
- Lakshminarayanan et al. “Deep Ensembles.” citeturn1search0turn1search4  
- Gal, Ghahramani. “Dropout as a Bayesian Approximation.” citeturn1search1turn1search5  
- Blundell et al. “Weight Uncertainty in Neural Networks (Bayes by Backprop).” citeturn1search2turn1search6  
- Angelopoulos, Bates. “A Gentle Introduction to Conformal Prediction.” citeturn2search0turn2search8  
- Geifman, El-Yaniv. “Selective Classification for Deep Neural Networks.” citeturn2search1turn2search5  

Weak supervision:
- Ratner et al. “Data Programming: Creating Large Training Sets, Quickly.” citeturn0search18turn3search23  
- Ratner et al. “Snorkel: Rapid Training Data Creation with Weak Supervision.” citeturn0search2turn0search10  
- Snorkel LabelModel docs (P(lf|Y) framing). citeturn2search18  
- Bach et al. “Learning the Structure of Generative Models without Labeled Data.” citeturn2search6  
- Ratner et al. “Training Complex Models with Multi-Task Weak Supervision.” citeturn3search0turn3search8  

Evidence/rationales:
- Jain, Wallace. “Attention is not Explanation.” citeturn13search0turn13search4  
- Lei, Barzilay, Jaakkola. “Rationalizing Neural Predictions.” citeturn13search1turn13search5  
- DeYoung et al. “ERASER benchmark.” citeturn13search2turn13search14  

Production ML architecture:
- TFX platform paper. citeturn6search5  
- Google Cloud MLOps architecture using TFX/Kubeflow. citeturn6search1  
- Continuous training for production ML (TFX). citeturn6search21  
- Feast feature store intro and docs. citeturn6search10turn6search6  
- MLflow paper + registry docs. citeturn6search19turn6search15  
- BentoML and Seldon Core serving docs. citeturn7search0turn7search5  

Security, indexing, lineage:
- PostgreSQL RLS and CREATE POLICY docs. citeturn8search4turn8search0  
- Supabase RLS guidance. citeturn8search1  
- PostgreSQL GIN index docs. citeturn8search2  
- OpenLineage specification/object model. citeturn8search27turn8search3