# 04 — Legacy Foundations Summary

This vision is not starting from zero. It inherits a set of “contracts” that were built to solve hard problems:

## 1) Continuity contracts: thread vs project
Legacy work established that “conversation continuity” is not the same as “project continuity.”

- A thread/topic may link messages without promoting a project attribution.
- A project promotion requires stronger evidence.

This remains a core guardrail: we can preserve context without making fragile project assertions.

## 2) Evidence receipts: grounded vs proxy
Legacy work pushed toward separating evidence derived from transcripts/artifacts vs proxy sources.

Even though earlier receipt blob designs may be obsolete, the idea survives as a simple principle:
- store the evidence needed to explain a decision at the same level the decision is made (span-level).

## 3) World model bootstrapping: multi-pass labeling
Legacy plans favored multi-pass labeling:
- deterministic labels → graph propagation → lightweight triage → deep labeling → human queue → eval.

The future vision keeps this, but elevates the safety rule:
- nothing writes irreversible world-model state without auditability and circuit breakers.

## 4) Identity resolution gates
Legacy specs emphasized cautious merging of identities. That’s foundational:
- identity errors are multiplicative; they poison every downstream inference.

## 5) Evaluation harness + taxonomy
Legacy GT taxonomy work treated “evaluation” as first-class, not an afterthought.
The vision keeps evaluation as a gate: if we can’t measure it, we shouldn’t automate it.

## 6) Operational discipline: capability registry and cold agent detection
Legacy docs show a pattern: operations are part of product quality.
A multi-agent system without visibility creates silent failures.
The future vision assumes operational instrumentation is a prerequisite to scaling.

## 7) Architecture map as source of truth
Legacy work insisted the diagram match reality.
That is not cosmetic; it is how we prevent accidental complexity from becoming permanent.

---

## What we simplify going forward

- Replace sprawling “receipt schema blobs” with a small, stable evidence contract.
- Replace ad-hoc learning writes with an append-only ledger plus circuit breakers.
- Replace “feature lists” with habit surfaces tied to measurable outcomes.
