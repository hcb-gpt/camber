/**
 * rrf_tier_guardrail.ts — M2-E post-inference guardrail
 *
 * Adjusts ai-router attribution decisions based on RRF evidence tier labels
 * computed by context-assembly (M2-D). Downgrades weak/anti tier assigns to
 * review; boosts smoking_gun confidence floor.
 *
 * Slots into the guardrail chain between world-model guardrail (step 8) and
 * homeowner deterministic override (step 9).
 *
 * Feature-flagged via RRF_TIER_GUARDRAIL_ENABLED env var (default false).
 */

type Decision = "assign" | "review" | "none";

export type EvidenceTierLabel =
  | "smoking_gun"
  | "strong"
  | "moderate"
  | "weak"
  | "anti";

export interface RrfTierGuardrailInput {
  decision: Decision;
  project_id: string | null;
  confidence: number;
  candidates: Array<{
    project_id: string;
    evidence: {
      rrf_score?: number;
      evidence_tier_label?: string;
    };
  }>;
}

export interface RrfTierGuardrailResult {
  decision: Decision;
  confidence: number;
  downgraded: boolean;
  boosted: boolean;
  reason_code: string | null;
  chosen_tier: string | null;
  chosen_rrf_score: number | null;
}

const VALID_TIERS = new Set<string>([
  "smoking_gun",
  "strong",
  "moderate",
  "weak",
  "anti",
]);

/** Confidence floor applied when smoking_gun tier is present. */
const SMOKING_GUN_CONFIDENCE_FLOOR = 0.85;

/**
 * Apply RRF tier guardrail to the LLM attribution result.
 *
 * Rules:
 * 1. If decision=assign and chosen project tier is "weak" or "anti",
 *    downgrade to review (insufficient retrieval signal for auto-assign).
 * 2. If chosen project tier is "smoking_gun" and confidence < 0.85,
 *    boost confidence to 0.85 floor (strong multi-channel retrieval signal).
 * 3. All other cases pass through unchanged.
 */
export function applyRrfTierGuardrail(input: RrfTierGuardrailInput): RrfTierGuardrailResult {
  const passthrough: RrfTierGuardrailResult = {
    decision: input.decision,
    confidence: input.confidence,
    downgraded: false,
    boosted: false,
    reason_code: null,
    chosen_tier: null,
    chosen_rrf_score: null,
  };

  if (!input.project_id) return passthrough;

  const chosen = (input.candidates || []).find((c) => c.project_id === input.project_id);
  if (!chosen) return passthrough;

  const tierRaw = chosen.evidence?.evidence_tier_label || null;
  const rrfScore = chosen.evidence?.rrf_score ?? null;

  // No tier info or unrecognized tier -- pass through
  if (!tierRaw || !VALID_TIERS.has(tierRaw)) {
    return {
      ...passthrough,
      chosen_rrf_score: rrfScore,
    };
  }

  const tier = tierRaw as EvidenceTierLabel;
  let decision = input.decision;
  let confidence = input.confidence;
  let downgraded = false;
  let boosted = false;
  let reason_code: string | null = null;

  // Rule 1: Downgrade assign on weak/anti tier
  if (decision === "assign" && (tier === "weak" || tier === "anti")) {
    decision = "review";
    downgraded = true;
    reason_code = `rrf_tier_${tier}_downgrade`;
  }

  // Rule 2: Boost smoking_gun confidence floor (only if not downgraded)
  if (!downgraded && tier === "smoking_gun" && confidence < SMOKING_GUN_CONFIDENCE_FLOOR) {
    confidence = SMOKING_GUN_CONFIDENCE_FLOOR;
    boosted = true;
    reason_code = "rrf_tier_smoking_gun_boost";
  }

  return {
    decision,
    confidence,
    downgraded,
    boosted,
    reason_code,
    chosen_tier: tier,
    chosen_rrf_score: rrfScore,
  };
}
