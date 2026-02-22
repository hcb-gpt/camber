/**
 * M2-E: RRF Reranker — Evidence-tier weighted reranking for ai-router
 *
 * Combines RRF fusion scores (from context-assembly M2-D) with evidence-tier
 * weights to produce final_score per candidate. Candidates are reranked by
 * final_score descending before being surfaced in the LLM judge prompt.
 *
 * Backward compatible: if rrf_score is not present on a candidate, falls back
 * to existing source_strength-based scoring (no reranking applied).
 */

// ============================================================
// TIER WEIGHTS
// ============================================================

export type EvidenceTierLabel =
  | "smoking_gun"
  | "strong"
  | "moderate"
  | "weak"
  | "anti";

export const TIER_WEIGHTS: Record<EvidenceTierLabel, number> = {
  smoking_gun: 5.0,
  strong: 3.0,
  moderate: 1.0,
  weak: 0.5,
  anti: -1.0,
};

const VALID_TIERS = new Set<string>(Object.keys(TIER_WEIGHTS));

// ============================================================
// TIER CLASSIFICATION
// ============================================================

/**
 * Classify a candidate's evidence into a named tier based on its existing
 * evidence signals. This maps the existing ai-router evidence model
 * (source_strength, assigned flag, alias_matches, anchor types) into the
 * 5-tier system.
 *
 * If the candidate already has an evidence_tier_label from context-assembly,
 * that takes precedence.
 */
export function classifyEvidenceTier(evidence: {
  sources?: string[];
  affinity_weight?: number;
  source_strength?: number;
  assigned?: boolean;
  alias_matches?: Array<{ term: string; match_type: string }>;
  evidence_tier_label?: string;
}): EvidenceTierLabel {
  // If context-assembly already classified the tier, trust it
  if (evidence.evidence_tier_label && VALID_TIERS.has(evidence.evidence_tier_label)) {
    return evidence.evidence_tier_label as EvidenceTierLabel;
  }

  const sourceStrength = evidence.source_strength ?? 0;
  const assigned = evidence.assigned === true;
  const aliasMatches = evidence.alias_matches ?? [];

  // Strong anchor match types that indicate high-quality evidence
  const strongMatchTypes = new Set([
    "exact_project_name",
    "alias",
    "address_fragment",
    "client_name",
    "chain_continuity",
  ]);

  const hasStrongMatch = aliasMatches.some((m) => strongMatchTypes.has(m.match_type));

  // smoking_gun: assigned contact with strong match and high source_strength
  if (assigned && hasStrongMatch && sourceStrength >= 1.0) {
    return "smoking_gun";
  }

  // strong: strong match OR (assigned + moderate source_strength)
  if (hasStrongMatch || (assigned && sourceStrength >= 0.5)) {
    return "strong";
  }

  // moderate: has some evidence (any alias match, or non-trivial source_strength)
  if (aliasMatches.length > 0 || sourceStrength >= 0.2) {
    return "moderate";
  }

  // weak: has some signal but very low
  if (sourceStrength > 0 || (evidence.sources && evidence.sources.length > 0)) {
    return "weak";
  }

  // anti: no positive signal at all
  return "anti";
}

// ============================================================
// RRF RERANKER
// ============================================================

export interface RerankCandidate {
  project_id: string;
  rrf_score?: number;
  evidence_tier_label?: string;
  evidence: {
    sources?: string[];
    affinity_weight?: number;
    source_strength?: number;
    assigned?: boolean;
    alias_matches?: Array<{ term: string; match_type: string }>;
    evidence_tier_label?: string;
    rrf_score?: number;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface RerankResult {
  candidates: RerankCandidate[];
  reranked: boolean;
  scores: Array<{
    project_id: string;
    rrf_score: number;
    tier: EvidenceTierLabel;
    tier_weight: number;
    final_score: number;
  }>;
}

/**
 * Rerank candidates using RRF scores weighted by evidence tier.
 *
 * For each candidate:
 *   final_score = rrf_score * TIER_WEIGHTS[tier]
 *
 * Candidates are sorted by final_score descending.
 *
 * If no candidates have rrf_score, returns the original order (no reranking).
 */
export function rerankCandidates(candidates: RerankCandidate[]): RerankResult {
  if (!Array.isArray(candidates) || candidates.length === 0) {
    return { candidates: [], reranked: false, scores: [] };
  }

  // Check if any candidate has an rrf_score
  const hasAnyRrfScore = candidates.some(
    (c) => typeof (c.evidence?.rrf_score ?? c.rrf_score) === "number",
  );

  if (!hasAnyRrfScore) {
    // No RRF scores available — return original order, no reranking
    return { candidates, reranked: false, scores: [] };
  }

  const scored = candidates.map((c) => {
    const rrfScore = typeof c.evidence?.rrf_score === "number"
      ? c.evidence.rrf_score
      : typeof c.rrf_score === "number"
      ? c.rrf_score
      : 0;

    const tier = classifyEvidenceTier(c.evidence || {});
    const tierWeight = TIER_WEIGHTS[tier];
    const finalScore = rrfScore * tierWeight;

    return {
      candidate: c,
      rrf_score: rrfScore,
      tier,
      tier_weight: tierWeight,
      final_score: finalScore,
    };
  });

  // Sort by final_score descending (stable sort preserves original order for ties)
  scored.sort((a, b) => b.final_score - a.final_score);

  return {
    candidates: scored.map((s) => s.candidate),
    reranked: true,
    scores: scored.map((s) => ({
      project_id: s.candidate.project_id,
      rrf_score: s.rrf_score,
      tier: s.tier,
      tier_weight: s.tier_weight,
      final_score: s.final_score,
    })),
  };
}

// Post-inference guardrail is in rrf_tier_guardrail.ts (separate module)
