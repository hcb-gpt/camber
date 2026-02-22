# GT v3 span_not_found triage probe

Date: 2026-02-18
Status: PASS (5-interaction fallback probe)

## Evidence: failing interactions from 20260218T032835Z
- `cll_06E3K1VVKNT435XKDTRBNB8QD0`
- `cll_06E3HS7S75RQK080ZN7K9Q84B0`
- `cll_06E3HG24Q9YM7BGK44NCQRV2Z8`
- `cll_06E3HEWTR5RDD39AJK7PZ8G4X8`
- `cll_06E3HCJ3KSY1K9B2RGECN5GNQM`

## Source inspection (pre-fix state)
All five interactions had no `transcripts_comparison` transcript row (latest transcript length = 0), while `calls_raw.transcript` contained full transcripts.

## Repro run (post-fix)
Ran 5 direct `admin-reseed` calls with:
`mode: resegment_and_reroute`, `force: true` (to remove stale spans), unique idempotency keys.

## Results
| interaction_id | span_count_before | span_count_after | status |
| --- | ---: | ---: | --- |
| cll_06E3K1VVKNT435XKDTRBNB8QD0 | 0 | 1 | success |
| cll_06E3HS7S75RQK080ZN7K9Q84B0 | 0 | 2 | success |
| cll_06E3HG24Q9YM7BGK44NCQRV2Z8 | 0 | 2 | success |
| cll_06E3HEWTR5RDD39AJK7PZ8G4X8 | 0 | 2 | success |
| cll_06E3HCJ3KSY1K9B2RGECN5GNQM | 0 | 2 | success |

## Conclusion
`span_not_found` was caused by missing transcript source in reseed: `transcripts_comparison` empty and fallback from existing spans unavailable after force delete. New `calls_raw` fallback in `admin-reseed` resolves this for probe interactions.
