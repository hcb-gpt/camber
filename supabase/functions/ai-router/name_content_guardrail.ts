/**
 * Name-vs-Content Guardrail
 *
 * Detects when the LLM likely chose a project based on a person's name
 * appearing in transcript (name coincidence) rather than actual construction
 * content matching the project's claim pointers.
 *
 * Root cause: Permar Residence under-attribution. When "Lou Winship" (a person)
 * is mentioned, the router assigns to "Winship Residence" even though the
 * construction work (fireplace, stone, windows at Sparta) matches Permar's
 * claim pointers at 0.90+ confidence.
 *
 * Fix: When the chosen project has low claim_crossref_score and a competing
 * candidate has significantly higher crossref, downgrade assign->review.
 *
 * @version 1.0.0
 * @date 2026-02-22
 */

// ============================================================
// TYPES
// ============================================================

export interface NameContentGuardrailCandidate {
  project_id: string;
  project_name: string;
  evidence: {
    claim_crossref_score?: number;
    source_strength?: number;
    alias_matches: Array<{ term: string; match_type: string }>;
  };
}

export interface NameContentGuardrailInput {
  decision: "assign" | "review" | "none";
  project_id: string | null;
  confidence: number;
  reasoning: string;
  candidates: NameContentGuardrailCandidate[];
}

export interface NameContentGuardrailResult {
  decision: "assign" | "review" | "none";
  confidence: number;
  reasoning: string;
  applied: boolean;
  reason: string | null;
  rival_project_id: string | null;
  rival_crossref: number;
  chosen_crossref: number;
}

// ============================================================
// THRESHOLDS
// ============================================================

/** Chosen project crossref below this is considered "low content match" */
const CHOSEN_CROSSREF_LOW = 0.10;

/** Rival project crossref above this is considered "strong content match" */
const RIVAL_CROSSREF_HIGH = 0.30;

/** Minimum gap between rival and chosen crossref to trigger guardrail */
const CROSSREF_GAP_MIN = 0.20;

// ============================================================
// GUARDRAIL
// ============================================================

/**
 * Evaluate whether the LLM's assignment is likely driven by name coincidence
 * rather than content matching. If so, downgrade to review.
 *
 * Conditions for triggering (ALL must be true):
 * 1. decision is "assign"
 * 2. chosen project has claim_crossref_score < CHOSEN_CROSSREF_LOW
 * 3. at least one rival candidate has claim_crossref_score >= RIVAL_CROSSREF_HIGH
 * 4. gap between rival and chosen crossref >= CROSSREF_GAP_MIN
 */
export function applyNameContentGuardrail(
  input: NameContentGuardrailInput,
): NameContentGuardrailResult {
  const noOp: NameContentGuardrailResult = {
    decision: input.decision,
    confidence: input.confidence,
    reasoning: input.reasoning,
    applied: false,
    reason: null,
    rival_project_id: null,
    rival_crossref: 0,
    chosen_crossref: 0,
  };

  // Only applies to assign decisions
  if (input.decision !== "assign" || !input.project_id) {
    return { ...noOp, reason: "not_assign" };
  }

  const candidates = input.candidates || [];
  if (candidates.length < 2) {
    return { ...noOp, reason: "single_candidate" };
  }

  // Find chosen candidate
  const chosen = candidates.find((c) => c.project_id === input.project_id);
  if (!chosen) {
    return { ...noOp, reason: "chosen_not_found" };
  }

  const chosenCrossref = chosen.evidence?.claim_crossref_score ?? 0;

  // Chosen project must have LOW content match
  if (chosenCrossref >= CHOSEN_CROSSREF_LOW) {
    return { ...noOp, reason: "chosen_crossref_sufficient", chosen_crossref: chosenCrossref };
  }

  // Find the strongest rival by crossref
  let bestRival: NameContentGuardrailCandidate | null = null;
  let bestRivalCrossref = 0;

  for (const c of candidates) {
    if (c.project_id === input.project_id) continue;
    const crossref = c.evidence?.claim_crossref_score ?? 0;
    if (crossref > bestRivalCrossref) {
      bestRivalCrossref = crossref;
      bestRival = c;
    }
  }

  if (!bestRival) {
    return { ...noOp, reason: "no_rival", chosen_crossref: chosenCrossref };
  }

  // Rival must have HIGH content match
  if (bestRivalCrossref < RIVAL_CROSSREF_HIGH) {
    return {
      ...noOp,
      reason: "rival_crossref_low",
      rival_project_id: bestRival.project_id,
      rival_crossref: bestRivalCrossref,
      chosen_crossref: chosenCrossref,
    };
  }

  // Gap must be significant
  const gap = bestRivalCrossref - chosenCrossref;
  if (gap < CROSSREF_GAP_MIN) {
    return {
      ...noOp,
      reason: "crossref_gap_insufficient",
      rival_project_id: bestRival.project_id,
      rival_crossref: bestRivalCrossref,
      chosen_crossref: chosenCrossref,
    };
  }

  // All conditions met: downgrade to review
  return {
    decision: "review",
    confidence: Math.min(input.confidence, 0.70),
    reasoning:
      `${input.reasoning} name_content_guardrail: chosen project ${chosen.project_name} has low content match (crossref=${
        chosenCrossref.toFixed(2)
      }) while ${bestRival.project_name} has strong content match (crossref=${
        bestRivalCrossref.toFixed(2)
      }). Downgraded to review — likely name-in-transcript confusion.`,
    applied: true,
    reason: "name_content_mismatch",
    rival_project_id: bestRival.project_id,
    rival_crossref: bestRivalCrossref,
    chosen_crossref: chosenCrossref,
  };
}
