# ORBIT Engineering Policies v1.0

> Effective: 2026-03-01
> Authority: Chad (Org Health Audit)
> Enforcement: STRAT
> Applies to: All DEV, DATA, and STRAT sessions

---

## 1. Branch Naming

All branches must follow the naming convention:

| Pattern | Use case |
|---------|----------|
| `feat/<epic>/<desc>` | New features |
| `fix/<issue>/<desc>` | Bug fixes |
| `agent/<session>/<task>` | Agent-driven work |

- No agent creates a branch without announcing it via TRAM CLAIM with the branch name.
- Default branch: **`master`**

## 2. Claim-Before-Work

Every TRAM CLAIM must list the files, functions, tables, views, or Edge Functions being touched.

- STRAT checks for overlap before ACKing.
- Working without a CLAIM is a violation.
- If your scope overlaps another agent's active CLAIM, **STOP** and escalate to STRAT immediately.

## 3. TEST_PROOF Required

Every COMPLETION receipt must include `TEST_PROOF`:

- Unit test output
- E2E gate result
- Manual verification steps with evidence

No TEST_PROOF = NACK. STRAT will bounce it back.

## 4. Completion Quality Bar

Every completion requires all four:

| Field | Description |
|-------|-------------|
| `GIT_PROOF` | Commit SHA or PR link |
| `DB_PROOF` | Query results, migration confirmation (if applicable) |
| `TEST_PROOF` | Test output or verification evidence |
| `USER_BENEFIT` | One sentence describing the impact for end users |

Missing any = NACK.

## 5. Retirement Cleanup

When retiring a session:

- Delete all branches you created that have been merged.
- Escalate unmerged branches to STRAT with status and context.

---

## Secret Hygiene

- Never log secrets in TRAM messages or transcripts.
- Document every secret and where it lives.
- STRAT owns the secret inventory. DEV/DATA request access through TRAM — do not self-serve.

## Non-Compliance

| Occurrence | Action |
|------------|--------|
| First | STRAT flags it in TRAM, agent corrects |
| Second | Task reassigned to a different agent |
| Pattern | Session deprioritized for high-value work |

---

_These are the minimum standards for a team shipping production code to real users._
