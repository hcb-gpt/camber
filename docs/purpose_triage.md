# Triage Purpose + Bugbash Checklist

## Purpose

Triage exists to let Chad clear attribution decisions quickly, with confidence, while staying in flow.  
“Better” means each card can be resolved in seconds, failures are obvious/recoverable, and decisions persist immediately.

## Definition of Done (what Chad should feel)

- I can process cards continuously without UI stalls or confusion.
- Swipes/actions are predictable and reversible (undo window works).
- The queue visibly advances and stays advanced after refresh.
- I trust that each action is persisted and won’t silently disappear.

## 10-Step Pre-Ship Bugbash (swipe/click)

1. Launch app on `ship/latest` and wait for first screen render.
2. Tap `Triage`.
3. Swipe first card left (dismiss/no-project path) and confirm queue advances.
4. Swipe second card left and confirm queue advances.
5. Swipe third card left and confirm queue advances.
6. Confirm triage run completes without crash or stuck spinner.
7. Tap `Assistant`.
8. Submit prompt: “What is going on recently?”
9. Submit prompt: “What are the top urgent contacts right now?”
10. Return to `Redline` tab and confirm app remains responsive.
