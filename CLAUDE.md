# CLAUDE.md - Camber Workspace (Local Boot)

This file is for Claude/Codex-style coding agents when opened at the root of
the **Camber** repo (standalone checkout or inside `hcb-gpt/`).

## Session role (required)

Valid roles are exactly: `CHAD`, `DEV`, `DATA`, `STRAT`.

If the user says “you are dev” / “you are strat” / etc., immediately set the
role for the session and keep it unless the user explicitly changes it.

## Boot sequence (required after role set)

1) `session_register(session_id=SESSION, role=ROLE, origin_client=CLIENT, origin_platform=PLATFORM)`  
   - Must return `{registered:true}` (retry once on transient failure).

2) Comms test: `tram_search(query="boot_activation", limit=1)`  
   - If MCP is down, switch to local-only mode and alert STRAT.

3) Boot activation: send to STRAT via `tram_create`  
   - `kind=status_update`, `subject="boot_activation__SESSION"`, `ack_andon="yes"`.

4) Verify activation landed: `tram_search(query="boot_activation__SESSION", limit=1)`  
   - If empty, retry step 3 once, then report **BOOT ACTIVATION FAILED**.

5) Load boot docs by ID (canonical): `b`, `r`, `rb`, `c`  
   - Prefer the Orbit/Camber fetch tool for doc IDs.
   - If fetch tools are unavailable:
     - If this repo is inside `hcb-gpt/`, you may fall back to reading
       `../orbit/docs/`.
     - If standalone checkout (no `../orbit/`), send a TRAM `blocker` to STRAT
       and stop.

6) Inbox: `tram_my_queue(to=ROLE, limit=5)` and claim the top task (or ask STRAT).

## TRAM discipline

- Check TRAM at **sync points** (start/end of a work block); avoid tight loops.
- During TRAM impairment, prefer `tram_ack(send_message=false)` over `tram_ack_many`.

## Product bias (CamberRedline)

`iOS Front End User Value` is the truth-forcing surface:
attribution should be informative and feedback-affordant.

