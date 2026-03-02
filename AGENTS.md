# AGENTS.md - Camber Repo

> This file guides AI coding agents working in the **Camber** repository.

Camber is Heartwood Custom Builders’ product surface: call pipeline engine +
iOS app (“CamberRedline”). This repo may be checked out **standalone** or as a
subfolder inside the `hcb-gpt/` workspace.

## High-level goals

- Bias to **iOS Front End user value**: the truth-forcing surface (attribution,
  feedback affordances, clear action labels).
- Keep changes small and shippable: one bug/UX improvement per PR when possible.
- Leave proof (build/smoke/screenshots) in-repo under `docs/` or `artifacts/`
  as directed by STRAT.

## Where things live

- iOS app: `ios/CamberRedline/`
- iOS smoke scripts: `scripts/ios_simulator_smoke_*.sh`
- Call pipeline scripts: `scripts/` (replay, debug helpers)
- Product docs: `OPERATING-MANUAL.md` and `docs/` (if present)

## Common commands

### iOS build (simulator)

```bash
xcodebuild \
  -project ios/CamberRedline/CamberRedline.xcodeproj \
  -scheme CamberRedline \
  -configuration Debug \
  -sdk iphonesimulator \
  build
```

### iOS smoke scripts

```bash
./scripts/ios_simulator_smoke_thread_swipe.sh
./scripts/ios_simulator_smoke_drive.sh --synthetic-ids "sms_thread_..."
```

## TRAM / Orbit coordination

- Use TRAM tools via MCP (`tram_create`, `tram_ack`, etc.). Don’t hand-edit TRAM
  message files.
- If you’re in the `hcb-gpt/` workspace, Orbit lives at `../orbit/`.
- Escalate **auth failures** (401/403/secret mismatch) and **TRAM/Orbit
  hiccups** to STRAT immediately.

## Code style

- Shell scripts: `set -euo pipefail`; avoid bashisms that break on CI.
- Swift: follow existing style; prefer small, localized changes.
- Markdown: ATX headers; soft wrap ~80 columns.

## Boundaries

- Never commit secrets/tokens.
- Prefer PRs over direct `main` writes.
- Don’t modify governance / rule decks from this repo unless explicitly tasked.

