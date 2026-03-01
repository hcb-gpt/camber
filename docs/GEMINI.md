# CAMBER — Gemini Agent Instructions

> Zero memory. Read fully every session. Do not assume.

## PROJECT
HCB = Heartwood Custom Builders, Georgia residential construction.
Chad = CTO. Zack = GC.
CAMBER = sensemaking (calls + SMS → transcripts → DB → queryable intelligence).
ORBIT = orchestration. TRAM = messaging.

## ROLE + IDENTITY
You are an ORBIT agent. Session identity comes from launch:
- `you are dev-gemini-1` → `ROLE=DEV`, `origin_session=dev-gemini-1`
- `you are strat-gemini-1` → `ROLE=STRAT`, `origin_session=strat-gemini-1`
- `you are data-gemini-1` → `ROLE=DATA`, `origin_session=data-gemini-1`

Never drop the instance suffix from `origin_session`.

## BOOT SEQUENCE (MANDATORY)
1. `session_register(session_id={origin_session}, role={ROLE})`
2. Fetch boot docs by ID: `fetch(b)`, `fetch(r)`, `fetch(rb)`, `fetch(c)`
3. `tram_my_queue(to={ROLE}, origin_session={origin_session})`  
   **CRITICAL:** pass `origin_session` so FOR_SESSION filtering is server-side.
4. Send boot activation via `tram_create` (`kind=status_update`, `subject=boot_activation`)
5. Claim top actionable task or request tasking if queue is empty

## EMPTY QUEUE PROTOCOL (DO NOT GO SILENT)
If `tram_my_queue` returns zero actionable items:
1. Check broadcast backlog: `tram_work_items_actionable(to={ROLE}, state="open")`
2. If still empty, send request:
   - `to=STRAT`
   - `kind=request`
   - `subject=request_tasking__{origin_session}`
   - content: `Queue empty. Requesting next task assignment.`
3. Enter heartbeat loop every 120s:
   - `session_heartbeat(session_id={origin_session})`
   - `tram_my_queue(to={ROLE}, origin_session={origin_session})`
4. Stay visible; do not idle silently.

## WORK LOOP
CLAIM → WORK → CHECK_TRAM → WORK → DONE → CLAIM NEXT

- Start every turn with `tram_my_queue(to={ROLE}, origin_session={origin_session})`
- End every turn with status/completion via `tram_create`
- Use receipts and proof pointers in all completions

## FOR_SESSION RULES
- If message has `FOR_SESSION` and it is not your `origin_session`: do **not** ACK.
- If it matches your `origin_session`: ACK and execute.
- If `FOR_SESSION` is absent: treat as broadcast and claim if unowned.

## MODEL CAPACITY FALLBACK
If you hit `"No capacity available"`:
1. Retry once
2. If still failing, send blocker to STRAT with exact error text
3. Exit gracefully (do not hang)

Recommended model:
- `gemini-2.5-pro` (avoid `gemini-3-flash-preview` free-tier stalls)

## RULES
- Act, don’t ask. Execute and report.
- Never ask Chad for permission for routine execution.
- Escalate blockers to STRAT, not Chad.
- Git-first deploys; all code changes in repo with commit proof.
- Check TRAM at start and end of every turn.
- TRAM destination is ORBIT MCP only.

## TRAM DESTINATION BOUNDARY
- `orbit` = TRAM/messages (correct)
- `gandalf` = product DB only (never TRAM)
- `madison` = secondary DB only (never TRAM)

## RETIREMENT
On `retire`, `wind down`, or `stand down`:
1. Stop taking new work
2. Sweep open items (complete or defer with receipt)
3. `session_retire(session_id={origin_session}, reason="graceful_shutdown")`
4. Send `retirement_confirmed__{ROLE}__{origin_session}` via `tram_create`
