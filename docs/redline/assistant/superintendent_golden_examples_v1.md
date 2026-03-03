# Superintendent Golden Examples v1

Source: `/Users/chadbarlow/Desktop/redline-ux-examples-v1.docx` (STRAT-VP, March 2, 2026).

Purpose: define acceptance for Redline assistant responses so output is sensemaking, not database regurgitation.

## Golden Prompts (v1)

1. Prompt: `tell me about permar`
Expected shape:
- Lead line states current status in plain language.
- Include latest meaningful activity using human time.
- Surface open loop if present.
- End with a useful next-step question.

2. Prompt: `whos at hurley tomorrow`
Expected shape:
- Directly answer who is confirmed and when.
- Connect calendar terms to the user question (`tomorrow`, `Tuesday morning`).
- Call out missing/unscheduled participants if relevant.
- Offer one operational follow-up.

3. Prompt: `did the inspector call back`
Expected shape:
- Start with explicit yes/no.
- Add who/when/context for last contact.
- State current gap duration in human terms.
- Suggest one concrete next action.

4. Prompt: `what do i owe eddie`
Expected shape:
- Lead with amount owed and basic math context.
- Include commitment timing if payment was promised.
- Flag next likely cost if clearly inferable.
- Offer follow-up across other outstanding payments.

5. Prompt: `anything i need to deal with`
Expected shape:
- Return short prioritized hit list by urgency.
- Include why each item matters now.
- Separate tracking-fine items from urgent items.
- Close with a next-step offer.

6. Prompt: `whats the holdup on woodbery`
Expected shape:
- Name the bottleneck in the first line.
- Show dependency chain in plain jobsite language.
- Call out risk of delay compounding.
- Give practical unblock suggestion.

## Banned Phrases And Tokens

Responses fail acceptance if they include any of:
- `UTC`
- `inbound`
- `outbound`
- `interaction` or `interactions`
- `these interactions show`
- ISO-like timestamps (`2026-03-01T16:12:00Z`)
- Chronological dump formatting that reads like raw logs

## Word Cap

- Default cap: `<= 200` words for the assistant response body.
- Exception: allow up to `240` words only when the user asks for a portfolio-wide triage summary.

## Human-Time Examples (Preferred)

- `this morning`
- `this afternoon`
- `yesterday evening`
- `tomorrow at 8`
- `3 days ago`
- `over a week ago`

## Acceptance Bar (Gut Check)

Pass only if this is true:
- A sharp project manager could say it out loud on a job site.
- The first two lines answer what the contractor is actually asking.
- The response ends with an actionable next-step prompt.
