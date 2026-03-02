# AGENTS.md - Camber Repo

> This file guides AI coding agents. See https://agents.md/ for the standard.

This repo (Camber) is sometimes checked out standalone (without a sibling `orbit/` repo).
Historically, `AGENTS.md`/`CLAUDE.md` were symlinks to `../orbit/*`, which breaks in
standalone worktrees. These files are now real, repo-local docs.

## Identity

You are working on **Camber**, the product repo (iOS app + call pipeline engine).

## Proof Standard

For any claim of progress, prefer the machine-parseable proof block:

- `USER_BENEFIT:` user-visible outcome
- `REAL_DATA_POINTER:` concrete ids + before/after counts
- `GIT_PROOF:` commit SHA (and PR link if available)

For iOS work, include:
- `BUILD_PROOF:` `xcodebuild` summary pointer
- `SIM_PROOF:` committed screenshot/video path (or other durable artifact)

## Useful Commands

```bash
# iOS simulator smoke (captures screenshots + mp4 under artifacts/)
./scripts/ios_simulator_smoke_drive.sh
./scripts/ios_simulator_smoke_thread_swipe.sh

# Repo tests (edit per current project conventions)
./TEST.md
```

## Repo Structure (high-level)

- `ios/` iOS app (CamberRedline)
- `scripts/` automation + smoke scripts
- `supabase/` database/edge function assets
- `tests/` test harnesses
- `proofs/` committed proof artifacts

## Scratch

Per Charter §17: never write scratch files to repo root.
Use:
- `.scratch/` for local scratch
- `.temp/` for larger ephemeral output
