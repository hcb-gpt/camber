


**TO:** Chad (STRAT CEO) & Strategy / Data Teams  
**FROM:** Mathematical/ML Specialist AI  
**SUBJECT:** Epistemological Architecture & Mathematical Foundations for Evidence-First Attribution  
**DATE:** March 1, 2026  

This memorandum outlines the rigorous mathematical and scientific foundation for Camber’s attribution engine. Per your strict constraints, this document contains no engineering code, schema definitions, or infrastructure migrations. It treats all implementation details as latent variables and defines the mathematical functions, statistical bounds, and epistemic principles required to guarantee system correctness, stability, and auditability.

At the end of this memo, I have included the exact abstract statistical distributions required to fit the parameters of these models. 

---

### 1. Weak Supervision Model: LF Aggregation & Dependence

To eliminate "confidence theater," we must decouple the generation of signals from their adjudication. We model the outputs of `context-assembly` as an $n \times m$ observation matrix $\Lambda \in \{0, 1, \dots, K\}^{n \times m}$, where $n$ is the number of spans, $m$ is the number of Labeling Functions (LFs), $K$ is the number of projects, and $0$ denotes an abstention. 

**1.1. The Label Model (Factor Graph Formulation)**
We cannot simply sum LF votes, as this naively assumes conditional independence: $P(\Lambda \mid Y) = \prod_{j} P(\lambda_j \mid Y)$. If $LF_{regex}$ and $LF_{llm\_semantic}$ fire on the same token, assuming independence artificially squares the evidence, causing runaway confidence. 

Instead, we model the true latent project $Y$ and the LF outputs $\Lambda$ using a generative probabilistic model (a Markov Random Field):
$$ P_{\theta}(\Lambda, Y) = \frac{1}{Z_\theta} \exp \left( \sum_{j=1}^m \theta_j \phi_j(\Lambda, Y) + \sum_{(j,k) \in C} \theta_{j,k} \phi_{j,k}(\Lambda, Y) \right) $$
Where:
*   $\phi_j$ are indicator functions for LF accuracies and propensities.
*   $\phi_{j,k}$ are correlation factors for dependent LF pairs in the set $C$.
*   $\theta$ are the learnable accuracy and correlation weights.

**1.2. Identifiability & Supervision Limits**
Under the Dawid-Skene paradigm, we can learn the accuracy parameters $\theta$ *without any ground truth labels* by observing the agreement and disagreement rates between LFs over a large unlabeled dataset, provided we have at least three conditionally independent LFs with accuracy better than random chance (the triplet method). 

If LFs are highly correlated, the covariance matrix becomes singular unless we inject a small amount of audited ground truth (a "tied" semi-supervised setup). 

**1.3. Two-Channel Evidence Contract**
We mathematically partition $\Lambda$ into two subsets: $\Lambda_{grounded}$ and $\Lambda_{proxy}$. 
The mapping function to an `AUTO_ASSIGN` state requires a Boolean conjunction:
$$ \text{Admissible}(x) = \left( \max_k P(Y=k \mid \Lambda) \ge \tau_{conf} \right) \land \left( \sum_{j \in \Lambda_{grounded}} \mathbb{I}(\lambda_j \neq 0) > 0 \right) $$
Proxy evidence can independently raise the marginal probability to trigger a `REVIEW`, but it is mathematically barred from satisfying the `AUTO_ASSIGN` admissibility predicate.

---

### 2. Evidential Inference & Subjective Logic

To represent UNKNOWN and CONFLICT as first-class mathematical states, we elevate our prediction from a categorical distribution (Softmax) to a **Dirichlet distribution** (a distribution over probability distributions).

**2.1. Mapping Evidence to Belief and Uncertainty**
Instead of the Label Model directly outputting a probability, we map the learned LF weights $\theta_j$ into strictly non-negative evidence masses $e_k \ge 0$ for each project $k$.
The Dirichlet parameters are defined as: $\alpha_k = e_k + W_{prior\_k} + 1$. 

The total Dirichlet strength (the Dirichlet precision) is $S = \sum_{k=1}^K \alpha_k$. 

In Subjective Logic (Dempster-Shafer theory), this yields three distinct epistemic dimensions:
1.  **Belief Mass:** $b_k = \frac{e_k + W_{prior\_k}}{S}$
2.  **Epistemic Uncertainty (Vacuity):** $u = \frac{K}{S}$
3.  **Dissonance (Conflict):** Measured via Information Entropy: $H = -\sum b_k \log_2 b_k$.

**2.2. Abstention Policy**
This mathematics forces honesty:
*   **The UNKNOWN State:** If $\Lambda = \mathbf{0}$ (no LFs fire), then $e_k = 0$ for all $k$. Therefore, $S = K$, and Epistemic Uncertainty $u = \frac{K}{K} = 1.0$. The system is mathematically forced to abstain.
*   **The NEEDS_SPLIT / CONFLICT State:** If $e_1$ (Project A) and $e_2$ (Project B) are both very high, the Belief masses $b_1$ and $b_2$ will both approach $0.5$. Uncertainty $u$ drops to near $0$, but Dissonance $H$ peaks. High $H$ with low $u$ strictly routes to `CONFLICT`.

---

### 3. Calibration & Selective Prediction

A high probability score is worthless if it does not match empirical correctness (e.g., if a system says it is 95% confident, it must be correct exactly 95% of the time).

**3.1. Avoiding Confidence Theater (Proper Scoring Rules)**
If an LLM adjudicator is trained via standard Cross-Entropy, it will suffer from systemic overconfidence. To enforce calibration, the offline evaluation must utilize strictly proper scoring rules, such as the Brier Score or Negative Log-Likelihood (NLL). If the Brier Score of a proposed model deployment regresses on the audited ground-truth set, the deployment must fail mathematically.

**3.2. Risk-Coverage Tradeoff & Operating Points**
Selective Classification (Geifman & El-Yaniv bounds) allows us to treat attribution as an optimization problem: *Maximize coverage (Auto-Assign rate) subject to the constraint that Risk (Error rate) $\le \epsilon$.*
By plotting the empirical Risk-Coverage (RC) curve, STRAT can scientifically select the confidence threshold $\tau_{conf}$. The threshold $0.92$ should not be a static guess; it should be dynamically fitted to guarantee the CEO's tolerated error rate $\epsilon$.

**3.3. Conformal Prediction (Candidate Generation)**
To guarantee $>99\%$ recall in candidate generation, we can apply Conformal Prediction. Given a calibration set and a tolerance $\alpha = 0.01$, Conformal Prediction outputs a candidate set $C(x)$ whose size expands dynamically based on the text's ambiguity, providing a distribution-free mathematical guarantee that $P(Y_{true} \in C(x)) \ge 1 - \alpha$. If $|C(x)|$ grows too large, it is an early indicator of upstream feature failure.

---

### 4. Human Feedback as Bayesian Updating

The `affinity_ledger` acts as the Bayesian prior $W_{prior}$. We must mathematically bound the updates to this prior to prevent positive feedback runaway (model sycophancy).

**4.1. Safe Update Operators**
We model the prior using a Beta distribution updated via human triage:
*   $\Delta \alpha_{k} = +1.0$ only upon deterministic human `CONFIRM` or `CORRECT`.
*   $\Delta \beta_{k} = +1.0$ applied strictly to runner-up candidates ($b_k > \tau_{runner\_up}$) that the human explicitly rejected. 
*   **The Stability Bound:** Model-generated auto-assignments ($\Delta W_{auto}$) must either be structurally barred from updating the prior, or discounted by a factor $\kappa \ll 1$ such that the expected drift $\kappa \cdot \mathbb{E}[N_{auto}]$ is strictly bounded by the human correction rate $\mathbb{E}[N_{human\_audit}]$. 

**4.2. Lifecycle-Aware Decay (Temporal Discounting)**
Priors must fade to account for the non-stationary nature of construction environments. We apply an exponential decay function evaluated at inference time:
$$ \tilde{W}_{prior}(t) = W_0 \cdot \exp(-\lambda_{lifecycle} \cdot \Delta t) $$
Where $\lambda_{lifecycle}$ is a piecewise parameter conditioned on project phase ($\lambda_{active} \approx 0$; $\lambda_{closed} \gg 0$).

---

### 5. High-Level Architecture Principles

**5.1. Strict Separation of Extraction and Adjudication**
The architecture must physically and logically divide the pipeline:
1.  **The Extractor (Feature Generator):** Emits $\Lambda_{grounded}$ and $\Lambda_{proxy}$. 
2.  **The Adjudicator (Reviewer/Scorer):** Accepts $\Lambda$ and outputs the Dirichlet posterior.

*The Hallucination Constraint:* The Adjudicator is a function $F(\Lambda)$. It is strictly forbidden from accessing the raw transcript $x$ if it bypassed the Extractor. It cannot invent evidence; it can only weigh the evidence $\Lambda$ provided to it. If $\Lambda$ is empty, $F(\Lambda)$ must yield UNKNOWN.

**5.2. Auditability and Lineage**
Every attribution must be a pure, functional derivation of its inputs. The output payload must contain the full trace: the precise values of $e_k$, the non-zero elements of $\Lambda_{grounded}$, and the exact $W_{prior}$ utilized. This transforms attribution from an opaque "AI decision" into a deterministic, verifiable cryptographic receipt.

---

### REQUIRED STATISTICAL RECONNAISSANCE 
*(To finalize parameter estimation and bounds)*

To calibrate the aforementioned mathematical models (Snorkel $\theta$ weights, Dirichlet thresholds, and Selective Classification bounds), I request the following abstract aggregate statistics. No schemas or code are required.

**Request A: LF Geometry & Dependence**
1.  **LF Coverage Distribution:** A vector representing the marginal probability of each labeling function firing (not abstaining) across a random sample of $N=10,000$ spans. 
2.  **LF Pairwise Agreement Matrix:** An $m \times m$ matrix where entry $(j,k)$ is the empirical probability that $LF_j$ and $LF_k$ output the same project given they both fired. *(Required to calculate covariance and prevent double-counting).*

**Request B: Calibration & Epistemics**
3.  **Risk-Coverage Curve Points:** Over a human-audited set of spans, what is the empirical precision (1 - risk) of the current model at confidence thresholds of $[0.80, 0.85, 0.90, 0.95, 0.99]$?
4.  **Evidence Mass Distribution:** For the subset of historical attributions that claimed $\ge 0.92$ confidence, what is the mean, median, and 5th-percentile count of discrete, grounded LF firings? *(Required to establish the baseline severity of confidence inflation).*

**Request C: Transition Dynamics**
5.  **Thread Boundary Gap Distribution:** A histogram of the time elapsed $\Delta t$ (in hours) between consecutive `interactions` for identical contacts. *(Required to fit the Hawkes process / exponential decay parameters for SMS context carryover).*

---

### Appendix: Key Scientific References
1.  **Weak Supervision:** Ratner, A., et al. (2017). *Snorkel: Rapid Training Data Creation with Weak Supervision*. VLDB.
2.  **Annotator Consensus:** Dawid, A. P., & Skene, A. M. (1979). *Maximum Likelihood Estimation of Observer Error-Rates*. Applied Statistics.
3.  **Evidential Inference:** Sensoy, M., et al. (2018). *Evidential Deep Learning to Quantify Classification Uncertainty*. NeurIPS.
4.  **Subjective Logic:** Jøsang, A. (2016). *Subjective Logic: A Formalism for Reasoning Under Uncertainty*. Springer.
5.  **Calibration:** Guo, C., et al. (2017). *On Calibration of Modern Neural Networks*. ICML.
6.  **Selective Classification:** Geifman, Y., & El-Yaniv, R. (2017). *Selective Classification for Deep Neural Networks*. NeurIPS.
7.  **Conformal Prediction:** Angelopoulos, A. N., & Bates, S. (2021). *A Gentle Introduction to Conformal Prediction and Distribution-Free Uncertainty Quantification*. Foundations and Trends in Machine Learning.