type Decision = "assign" | "review" | "none";

export interface NameVsContentCandidate {
  project_id: string;
  evidence?: {
    source_strength?: number;
    affinity_weight?: number;
    alias_matches?: Array<unknown>;
    assigned?: boolean;
  };
}

export interface NameVsContentGuardrailInput {
  decision: Decision;
  project_id: string | null;
  confidence: number;
  reasoning: string;
  candidates: NameVsContentCandidate[];
}

export interface NameVsContentGuardrailResult {
  decision: Decision;
  project_id: string | null;
  confidence: number;
  reasoning: string;
  applied: boolean;
  reason_code: string | null;
  from_project_id: string | null;
  to_project_id: string | null;
  winner_confidence: number | null;
  chosen_confidence: number | null;
  confidence_delta: number | null;
}

const MIN_DELTA_TO_OVERRIDE = 0.5;
const MIN_WINNER_CONFIDENCE = 0.65;
const AUTO_ASSIGN_FLOOR = 0.75;

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  if (value <= 0) return 0;
  if (value >= 1) return 1;
  return value;
}

function roundConfidence(value: number): number {
  return Math.round(clamp01(value) * 1000) / 1000;
}

function deriveCandidateEvidenceConfidence(candidate: NameVsContentCandidate): number {
  const sourceStrength = Number(candidate.evidence?.source_strength || 0);
  const affinityWeight = Number(candidate.evidence?.affinity_weight || 0);
  const aliasMatchCount = Array.isArray(candidate.evidence?.alias_matches)
    ? candidate.evidence?.alias_matches.length
    : 0;
  const aliasBoost = Math.min(aliasMatchCount, 4) * 0.08;
  const assignedBoost = candidate.evidence?.assigned ? 0.12 : 0;
  const rawScore = (sourceStrength * 0.6) + (affinityWeight * 0.3) + aliasBoost + assignedBoost;
  return roundConfidence(Math.max(sourceStrength, rawScore));
}

export function applyNameVsContentGuardrail(
  input: NameVsContentGuardrailInput,
): NameVsContentGuardrailResult {
  const passthrough: NameVsContentGuardrailResult = {
    decision: input.decision,
    project_id: input.project_id,
    confidence: input.confidence,
    reasoning: input.reasoning,
    applied: false,
    reason_code: null,
    from_project_id: null,
    to_project_id: null,
    winner_confidence: null,
    chosen_confidence: null,
    confidence_delta: null,
  };

  const chosenProjectId = String(input.project_id || "").trim();
  if (!chosenProjectId) return passthrough;

  const scored = (Array.isArray(input.candidates) ? input.candidates : [])
    .map((candidate) => {
      const projectId = String(candidate.project_id || "").trim();
      if (!projectId) return null;
      return {
        project_id: projectId,
        confidence: deriveCandidateEvidenceConfidence(candidate),
      };
    })
    .filter((row): row is { project_id: string; confidence: number } => Boolean(row));

  if (scored.length < 2) return passthrough;

  scored.sort((a, b) => b.confidence - a.confidence);
  const winner = scored[0];
  const chosen = scored.find((row) => row.project_id === chosenProjectId);
  if (!chosen) return passthrough;
  if (winner.project_id === chosenProjectId) return passthrough;

  const delta = roundConfidence(winner.confidence - chosen.confidence);
  if (winner.confidence < MIN_WINNER_CONFIDENCE || delta < MIN_DELTA_TO_OVERRIDE) {
    return {
      ...passthrough,
      chosen_confidence: chosen.confidence,
      winner_confidence: winner.confidence,
      confidence_delta: delta,
    };
  }

  const nextDecision: Decision = winner.confidence >= AUTO_ASSIGN_FLOOR ? "assign" : "review";
  const nextConfidence = nextDecision === "assign"
    ? Math.max(input.confidence, winner.confidence, AUTO_ASSIGN_FLOOR)
    : Math.max(input.confidence, winner.confidence, 0.5);

  return {
    decision: nextDecision,
    project_id: winner.project_id,
    confidence: roundConfidence(nextConfidence),
    reasoning:
      `${input.reasoning} name_vs_content_guardrail: promoted evidence-leading candidate when confidence_delta=${
        delta.toFixed(3)
      } (winner=${winner.confidence.toFixed(3)} vs chosen=${chosen.confidence.toFixed(3)}).`,
    applied: true,
    reason_code: "name_vs_content_weighting_override",
    from_project_id: chosen.project_id,
    to_project_id: winner.project_id,
    winner_confidence: winner.confidence,
    chosen_confidence: chosen.confidence,
    confidence_delta: delta,
  };
}
