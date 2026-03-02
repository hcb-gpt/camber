# 03 — North Star Metrics

The fastest way to drift is to measure outputs (pages shipped) rather than outcomes (trust and action).

These metrics are intentionally high-level; they describe what we want the system to become.

## Trust metrics (quality)

1) Evidence coverage
- % of user-facing claims that have a tappable evidence excerpt.

2) Attribution integrity
- % of interactions/spans correctly tied to a project (measured via QA samples + human feedback).

3) False certainty rate
- % of “high confidence” attributions later corrected by humans.

4) Learning safety
- # of circuit breaker trips (should exist; should be rare; must be visible).
- Time-to-freeze when trip conditions occur.

## Adoption metrics (habit)

1) Daily active usage of Morning Manifest
- How many days/week it is opened.
- “Clean completion rate”: % of tasks acted on without edits.

2) Redline correction throughput
- # of claims reviewed (confirm/reject/correct) per week.
- Median latency from claim creation → human verdict.

3) Time-to-answer
- Time for Zack/Chad to answer: “what’s the latest truth for Project X?”

## Leverage metrics (business outcomes)

1) Delay avoided
- # of long-lead items surfaced early enough to change ordering decisions.

2) Commitment closure
- % of commitments that end in a resolved state (done / explicitly dropped).

3) Rework reduction
- Fewer “wrong project” actions (calls, orders, site visits) triggered by misattribution.

## Platform health metrics (guardrails)

1) Staleness / freshness
- Pipeline stage freshness (worst-case age).
- Review freshness SLA.

2) Silent failure rate
- % of jobs marked “accepted” that did not produce expected writes.

3) Architecture visibility
- Diagram / map coverage: % of critical edges rendered and accurate.
