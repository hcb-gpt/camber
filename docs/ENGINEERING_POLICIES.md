# ORBIT Engineering Policies v1.0

1. BRANCH POLICY
- No agent creates a branch without announcing it via TRAM CLAIM with branch name
- Branch naming: feat/<epic>/<desc>, fix/<issue>/<desc>, agent/<session>/<task>
- Agent retirement sweep MUST delete merged branches
- Default branch: master

2. CLAIM-BEFORE-WORK
- Every CLAIM must list files/functions being touched
- STRAT checks for overlap before ACKing
- Working without a CLAIM = violation. If you discover an agent working without a CLAIM, file an escalation.

3. TEST_PROOF REQUIRED
- Every COMPLETION receipt must include TEST_PROOF: unit test output, E2E result, or verification steps
- No TEST_PROOF = NACK. STRAT will bounce it back.

4. SECRET HYGIENE
- Never log secrets in TRAM messages or transcripts
- Document every secret and where it lives
- STRAT owns secret inventory. DEV/DATA request access through TRAM, don't self-serve.

5. COMPLETION QUALITY BAR
- Every completion needs: GIT_PROOF (SHA), DB_PROOF (if applicable), TEST_PROOF, USER_BENEFIT (one sentence)
- Missing any = NACK
