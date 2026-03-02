


To: Chad (STRAT CEO)
From: Mathematical/ML Specialist AI 
Subject: Product-Grounded Evidential Inference for Camber Attribution

I have analyzed the live Camber map (`git_sha 992ad4ac...`), the 3,086 healthy attribution rows, and the critical failure you uncovered: **301 rows exhibiting "confidence theater"** ($\ge 0.92$ confidence with structurally empty `anchors`). 

You have a structural epistemology problem: `ai-router` is currently allowed to generate subjective confidence numbers independent of `context-assembly` facts. We must replace this black-box guessing with a mathematically bounded evidential ledger.

Here is the concrete, deployable math specification tailored strictly to your existing pipeline (`sms-thread-assembler` $\to$ `interactions` $\to$ `segment-call` $\to$ `context-assembly` $\to$ `ai-router`).

---

### RECOMMENDED APPROACH (THE LANE)
**Weak Supervision (Snorkel-style) + Dirichlet Evidential Inference**

**Why it fits the pipeline:** You already have the exact architecture needed for this. `context-assembly` acts as the execution engine for **Labeling Functions (LFs)** (e.g., entity matching, alias regex, affinity lookups). `ai-router` acts as just another semantic LF. Instead of letting `ai-router` output a final softmax percentage, we aggregate the discrete LF votes into a **Dirichlet distribution**. 
This mathematically guarantees that confidence $\ge 0.92$ is *impossible* to achieve unless sufficient grounded LFs fired in `context-assembly`. It structurally eliminates the 301 hallucinated rows.

---

### A) THREADING/WINDOWING: SOFT-BOUNDARY PROBABILITIES
The v5 `sms-thread-assembler` enforces a hard 4-hour gap. Do not rewrite this edge function right now; it is stable and idempotent via `thread_assembled_at`. Instead, treat the boundary as an epistemic soft link.

**The Model:** A Temporal Hidden Markov Model (HMM) Transition Proxy.
1. When `segment-call` creates spans for `interaction_id = sms_thread_{phone}_{t2}`, it queries the DB for the most recent thread `sms_thread_{phone}_{t1}`.
2. Calculate the **Boundary Continuity Score**: $P_{link} = \exp(-\lambda \Delta t) \cdot \mathbb{I}_{shared\_entities}$. (Set $\lambda$ such that a 12-hour gap decays to 0.2).
3. **Pipeline Action:** Pass the `context_receipt` of thread $t_1$ into the `context-assembly` of thread $t_2$, weighted by $P_{link}$. 
4. **Redline UX:** If an attribution relies on this carried-over context, the UI explicitly renders a chain-link icon: *"Context inherited from prior thread (Continuity Score: X%)."*

---

### B) ATTRIBUTION AS INFERENCE: THE DIRICHLET OBJECTIVE
Each interaction outputs a distribution over projects plus an explicit uncertainty mass.

**Objective & Math:**
Let each LF $j$ output a vote $v_{jk} \in [0, 1]$ for project $k$. 
Calculate evidence counts: $E_k = \sum_j W_j \cdot v_{jk}$
Dirichlet parameters: $\alpha_k = E_k + \alpha_{prior\_k}$

The distribution $P(y) \sim \text{Dir}(\boldsymbol{\alpha})$ gives us three guarantees:
1. **Probability:** $P(k) = \frac{\alpha_k}{\sum \alpha_i}$
2. **Epistemic Uncertainty:** $U = \frac{K}{\sum \alpha_i}$ (If no evidence exists, $U \to 1$)
3. **Information Entropy:** $H = - \sum P(k) \log P(k)$

**Detecting Spurious Certainty (The Admissibility Predicate):**
We define an admissibility predicate $A(row)$ that Redline enforces before displaying an AUTO badge:
$A(row) \iff (P_{max} \ge 0.92) \text{ AND } ( \sum_{j \in Grounded\_LFs} v_j > 0 )$
If $A(row)$ is false but $P_{max} \ge 0.92$, the model is hallucinating. Redline intercepts this, overrides to `UNKNOWN`, and logs an anomaly.

---

### C) BOOTSTRAPPING & WEAK SUPERVISION
We must learn the LF weights ($W_j$) from noisy labels (`triage_decisions` human locks).

**Sample Complexity Estimate (Packet 1):**
You asked for a guarantee that candidate generation achieves $>99\%$ recall. 
Using the binomial confidence interval ("Rule of Three"), if we want 95% confidence that our true miss rate is $< 1\%$, we need to observe $0$ misses in a sample size of $N \approx \frac{\ln(0.05)}{\ln(0.99)} \approx 298$. 
**Action:** Extract exactly $N=300$ ground-truth locked spans. If the true project is in the Top-K for all 300, your $>99\%$ recall is mathematically verified.

**Stable Negative Updates:**
When a human rejects an attribution, we only apply a negative update ($\Delta \beta = +1.0$) to the *runner-up* project if its posterior was $P > 0.30$. 
*Why this bounds drift:* Punishing *all* projects in the candidate set causes "epistemic collapse" where the model destroys its own priors for valid secondary projects. Capping the penalty to strong runner-ups restricts negative gradients strictly to regions of high model confusion.

---

### D) REDLINE "FORCES TRUTH" GATING METRICS
Redline is the execution layer for the math above. It reads the `span_attributions.anchors` JSONB and enforces these rules:

1. **The Entropy Gate (NEEDS_SPLIT):** 
   If $H > \log_2(1.5)$, the text strongly references multiple projects.
   *UI Action:* Block the "Confirm" button. Render a "Scissors" icon. Force the human to split the text.
2. **The Uncertainty Gate (LOW_CONFIDENCE):** 
   If $U > 0.3$, evidence is too sparse.
   *UI Action:* Badge turns yellow. Text reads: *"Sparse evidence. Prior suggests [Project X]."*
3. **The Provenance Gate (UNKNOWN):** 
   If $A(row) = \text{False}$, the evidence contract is broken.
   *UI Action:* Red bordered card. Text reads: *"No explicit anchors found."* 

---

### MINIMAL DATA ADDITIONS
1. **`interactions` table:** Add `prev_thread_interaction_id` (text) and `boundary_link_score` (numeric). Populated during `segment-call` to link the 4h SMS silos.
2. **`span_attributions` table:** No schema change, but enforce a strict JSONB contract on `anchors`:
   ```json
   {
     "grounded_lfs": {"LF_regex_woodberry": 1.0},
     "proxy_lfs": {"LF_prev_thread_carryover": 0.6, "LF_affinity": 0.8},
     "dirichlet_metrics": {"entropy": 0.12, "uncertainty": 0.05}
   }
   ```

---

### TEST PLAN (OFFLINE & SHADOW)
**1. Offline Replay (The Hallucination Purge):**
Extract the 301 specific rows from your probe where $P \ge 0.92$ but `anchors` is empty. Run them through the Dirichlet scoring logic using existing `context-assembly` outputs.
*Success Metric:* 100% of these 301 rows must mathematically collapse below $P < 0.92$ due to the absence of `grounded_lfs` counts. 

**2. Online Shadow Mode:**
Deploy the Dirichlet aggregator inside `ai-router`. Write the math to `span_attributions.anchors` but do not change the Redline UI yet.
*Success Metric:* Measure the "Abstain Rate" (where Dirichlet overrides the LLM's raw confidence down to `< 0.92`). We want to see a 15-20% abstain rate on raw SMS in week 1, pushing those to the human review queue to build ground truth.

---

### FAILURE MODES SPECIFIC TO YOUR PIPELINE
1. **The "Next Morning" SMS Orphan (Thread Boundary Failure):**
   *Scenario:* 10 PM thread discusses Woodberry. 8 AM next morning, client texts "Sounds good, order them." `sms-thread-assembler` cuts this into a new thread.
   *How we detect it:* Dirichlet uncertainty $U$ will be very high (no grounded names in "Sounds good"). However, `boundary_link_score` pulls in Woodberry as a `proxy_lf`. Redline gates it as `LOW_CONFIDENCE (Context Inherited)` rather than hallucinating absolute certainty.
2. **The "Floater" Subcontractor (Identity Collision):**
   *Scenario:* A plumber working 3 active jobs calls in. 
   *How we detect it:* `context-assembly` yields 3 graph matches. Entropy $H$ spikes. Redline blocks auto-assign, forcing a human to read the transcript and manually lock the `triage_decision`, which feeds the Snorkel label model to weigh down the "Subcontractor Graph" LF for that specific contact.