export function clientOverrideActsAsStrongAnchor(
  meta: Record<string, any> | null | undefined,
): boolean {
  const override = meta?.client_override === true;
  const conflictProjectId = typeof meta?.client_override_conflict_project_id === "string" &&
    meta.client_override_conflict_project_id.trim().length > 0;
  const conflictTerm = typeof meta?.client_override_conflict_term === "string" &&
    meta.client_override_conflict_term.trim().length > 0;
  return override && !conflictProjectId && !conflictTerm;
}

export interface ClientOverrideEvaluation {
  strong_anchor_active: boolean;
  deterministic_project_id: string | null;
  skip_reason:
    | "override_inactive_or_conflicted"
    | "missing_project_id"
    | "multi_project_span"
    | null;
}

/**
 * Client deterministic override is valid only when:
 * - context-assembly marked client_override=true and no contradiction metadata
 * - a concrete override project_id exists
 * - span does not look multi-project (multiple distinct candidate project_ids)
 */
export function evaluateClientOverride(
  meta: Record<string, any> | null | undefined,
  candidateProjectIds: Array<string | null | undefined> = [],
): ClientOverrideEvaluation {
  if (!clientOverrideActsAsStrongAnchor(meta)) {
    return {
      strong_anchor_active: false,
      deterministic_project_id: null,
      skip_reason: "override_inactive_or_conflicted",
    };
  }

  const projectId = typeof meta?.client_override_project_id === "string" ? meta.client_override_project_id.trim() : "";

  if (!projectId) {
    return {
      strong_anchor_active: false,
      deterministic_project_id: null,
      skip_reason: "missing_project_id",
    };
  }

  const uniqueCandidateIds = Array.from(
    new Set(
      candidateProjectIds
        .map((id) => (typeof id === "string" ? id.trim() : ""))
        .filter((id) => id.length > 0),
    ),
  );

  const hasConflictingCandidate = uniqueCandidateIds.some(
    (id) => id !== projectId,
  );
  if (hasConflictingCandidate) {
    return {
      strong_anchor_active: false,
      deterministic_project_id: null,
      skip_reason: "multi_project_span",
    };
  }

  return {
    strong_anchor_active: true,
    deterministic_project_id: projectId,
    skip_reason: null,
  };
}
