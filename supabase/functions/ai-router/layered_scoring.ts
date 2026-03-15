export interface ModelCandidateScore {
  project_id: string;
  confidence: number;
  anchor_type?: string | null;
}

export interface ScoringContribution {
  project_id: string;
  confidence: number;
  layer: string;
  rule_name: string;
  anchor_type?: string | null;
  rationale?: string | null;
}

export interface CombinedProjectScore {
  project_id: string;
  confidence: number;
  anchor_type: string;
  contributors: ScoringContribution[];
}

export interface CandidateSnapshotLike {
  project_id: string;
  confidence: number;
  anchor_type: string;
}

export interface CombinedScoreThresholds {
  review_threshold: number;
  assign_threshold: number;
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  if (value <= 0) return 0;
  if (value >= 1) return 1;
  return value;
}

function roundConfidence(value: number): number {
  return Math.round(clamp01(value) * 1000) / 1000;
}

function normalizeProjectId(value: unknown): string {
  return String(value || "").trim();
}

function normalizeConfidence(value: unknown): number {
  return roundConfidence(Number(value || 0));
}

export function normalizeModelCandidateScores(
  raw: unknown,
  fallbackProjectId: string | null,
  fallbackConfidence: number | null,
  fallbackAnchorType: string | null = null,
): ModelCandidateScore[] {
  const normalized = new Map<string, ModelCandidateScore>();

  if (Array.isArray(raw)) {
    for (const item of raw) {
      const projectId = normalizeProjectId((item as Record<string, unknown>)?.project_id);
      if (!projectId) continue;
      const confidence = normalizeConfidence((item as Record<string, unknown>)?.confidence);
      const anchorType = String((item as Record<string, unknown>)?.anchor_type || "").trim() || null;
      const existing = normalized.get(projectId);
      if (!existing || confidence > existing.confidence) {
        normalized.set(projectId, {
          project_id: projectId,
          confidence,
          anchor_type: anchorType,
        });
      }
    }
  }

  const fallbackProject = normalizeProjectId(fallbackProjectId);
  const fallbackScore = normalizeConfidence(fallbackConfidence);
  if (fallbackProject && fallbackScore > 0 && !normalized.has(fallbackProject)) {
    normalized.set(fallbackProject, {
      project_id: fallbackProject,
      confidence: fallbackScore,
      anchor_type: fallbackAnchorType,
    });
  }

  return Array.from(normalized.values()).sort((a, b) => b.confidence - a.confidence);
}

export function evaluateTranscriptSignal(
  modelScores: ModelCandidateScore[],
  thresholds: { min_confidence: number; review_threshold: number },
): {
  project_id: string | null;
  confidence: number;
  decision: "assign" | "review" | "none";
  runner_up_confidence: number | null;
  reason: string | null;
} {
  const top = modelScores[0] || null;
  const runnerUp = modelScores[1] || null;
  const runnerUpConfidence = runnerUp?.confidence ?? null;

  if (!top) {
    return {
      project_id: null,
      confidence: 0,
      decision: "none",
      runner_up_confidence: null,
      reason: null,
    };
  }

  const gap = runnerUp ? Math.abs(top.confidence - runnerUp.confidence) : top.confidence;
  const ratio = runnerUp && runnerUp.confidence > 0 ? top.confidence / runnerUp.confidence : Number.POSITIVE_INFINITY;

  if (top.confidence >= thresholds.min_confidence && ratio >= 2) {
    return {
      project_id: top.project_id,
      confidence: top.confidence,
      decision: "assign",
      runner_up_confidence: runnerUpConfidence,
      reason: `transcript_signal_ratio:${top.confidence.toFixed(2)}>${runnerUp?.confidence?.toFixed(2) || "0.00"}`,
    };
  }

  if (runnerUp && gap <= 0.1 && top.confidence >= thresholds.review_threshold) {
    return {
      project_id: top.project_id,
      confidence: top.confidence,
      decision: "review",
      runner_up_confidence: runnerUpConfidence,
      reason: `transcript_signal_close_call:${top.confidence.toFixed(2)}~${runnerUp.confidence.toFixed(2)}`,
    };
  }

  if (top.confidence >= thresholds.review_threshold) {
    return {
      project_id: top.project_id,
      confidence: top.confidence,
      decision: top.confidence >= thresholds.min_confidence ? "assign" : "review",
      runner_up_confidence: runnerUpConfidence,
      reason: `transcript_signal_top:${top.confidence.toFixed(2)}`,
    };
  }

  return {
    project_id: top.project_id,
    confidence: top.confidence,
    decision: "none",
    runner_up_confidence: runnerUpConfidence,
    reason: `transcript_signal_below_review:${top.confidence.toFixed(2)}`,
  };
}

export function combineProjectScores(contributions: ScoringContribution[]): CombinedProjectScore[] {
  const grouped = new Map<string, CombinedProjectScore>();

  for (const contribution of contributions) {
    const projectId = normalizeProjectId(contribution.project_id);
    const confidence = normalizeConfidence(contribution.confidence);
    if (!projectId || confidence <= 0) continue;

    const existing = grouped.get(projectId);
    if (!existing) {
      grouped.set(projectId, {
        project_id: projectId,
        confidence,
        anchor_type: String(contribution.anchor_type || contribution.rule_name || contribution.layer || "other").slice(
          0,
          64,
        ),
        contributors: [{
          ...contribution,
          project_id: projectId,
          confidence,
        }],
      });
      continue;
    }

    existing.contributors.push({
      ...contribution,
      project_id: projectId,
      confidence,
    });
    if (confidence > existing.confidence) {
      existing.confidence = confidence;
      existing.anchor_type = String(contribution.anchor_type || contribution.rule_name || contribution.layer || "other")
        .slice(0, 64);
    }
  }

  const combined = Array.from(grouped.values()).map((score) => {
    const distinctSources = new Set(
      score.contributors.map((contribution) => `${contribution.layer}:${contribution.rule_name}`),
    );
    const boosted = distinctSources.size > 1 ? Math.min(score.confidence + 0.1, 0.95) : score.confidence;
    return {
      ...score,
      confidence: roundConfidence(boosted),
    };
  });

  combined.sort((a, b) => b.confidence - a.confidence || a.project_id.localeCompare(b.project_id));
  return combined;
}

export function buildSnapshotsFromScores(opts: {
  scores: CombinedProjectScore[];
  chosen_project_id: string | null;
  chosen_confidence: number | null;
  chosen_anchor_type: string | null;
}): { top_candidates: CandidateSnapshotLike[]; runner_up_confidence: number | null; candidate_count: number } {
  const ranked = opts.scores.map((score) => ({
    project_id: score.project_id,
    confidence:
      score.project_id === normalizeProjectId(opts.chosen_project_id) && normalizeConfidence(opts.chosen_confidence) > 0
        ? normalizeConfidence(opts.chosen_confidence)
        : score.confidence,
    anchor_type: score.project_id === normalizeProjectId(opts.chosen_project_id) && opts.chosen_anchor_type
      ? String(opts.chosen_anchor_type).slice(0, 64)
      : score.anchor_type,
  }));

  ranked.sort((a, b) => b.confidence - a.confidence || a.project_id.localeCompare(b.project_id));

  return {
    top_candidates: ranked.slice(0, 5),
    runner_up_confidence: ranked.length > 1 ? ranked[1].confidence : null,
    candidate_count: ranked.length,
  };
}

export function chooseDecisionFromScores(
  scores: CombinedProjectScore[],
  thresholds: CombinedScoreThresholds,
): {
  project_id: string | null;
  confidence: number;
  decision: "assign" | "review" | "none";
  runner_up_confidence: number | null;
} {
  const top = scores[0] || null;
  const runnerUp = scores[1] || null;
  if (!top) {
    return {
      project_id: null,
      confidence: 0,
      decision: "none",
      runner_up_confidence: null,
    };
  }

  const confidence = normalizeConfidence(top.confidence);
  const runnerUpConfidence = runnerUp?.confidence ?? null;
  const decision = confidence >= thresholds.assign_threshold
    ? "assign"
    : confidence >= thresholds.review_threshold
    ? "review"
    : "none";

  return {
    project_id: top.project_id,
    confidence,
    decision,
    runner_up_confidence: runnerUpConfidence,
  };
}
