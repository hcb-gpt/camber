# Pre-operationalization recon tasks (science-first)

Date: 2026-03-01

Goal: ensure we are *mathematically informed* before operationalizing a major weak-supervision + evidential-inference change.

Constraint: deliverables are distributions, calibration curves, invariants, and threshold decisions — not schemas, code, SQL, or migrations.

## A) Reality check (Camber map + existing subsystems)
- Confirm system maturity and where the approach plugs in conceptually (evidence store, priors ledger, inference engine, gating policy).
Deliverable: 1-page “map + fit” note.

## B) Epistemic contract
- Define: grounded vs proxy evidence, admissibility, explicit states (UNKNOWN / CONFLICT / NEEDS_SPLIT / HUMAN_LOCK), and what is allowed to update priors.
Deliverable: contract memo.

## C) Weak supervision geometry
- LF coverage distribution; LF pairwise overlap/agree summary; conflict frequency; dependency detection; identifiability limits.
Deliverable: LF ecology report.

## D) Calibration + selective prediction
- Risk–coverage curve; calibration quality (ECE/reliability); evidence strength (Dirichlet mass) distribution for accepted predictions.
Deliverable: operating point selection + abstention regime.

## E) Human feedback as Bayesian updating
- Safe update operators; discounting; lifecycle-aware decay; what never updates; shadow-mode policy.
Deliverable: update memo with stability constraints.

## F) Circuit breakers + monitoring invariants
- Freeze conditions (precision breach, uncertainty inflation, conflict spike, drift); invariants (“no silent writes”).
Deliverable: circuit-breaker spec.

## G) Go/No-Go
- Gate 1: “science operational” (calibration artifacts + thresholds + breakers defined).
- Gate 2: “product operational” (proof gates + QA policy + rollback/freeze and a shadow period).
Deliverable: signed checklist.
