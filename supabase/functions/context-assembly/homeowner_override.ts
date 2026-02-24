export interface HomeownerAliasMatch {
  term?: string | null;
  match_type?: string | null;
}

export interface HomeownerOverrideCandidate {
  project_id: string;
  alias_matches?: HomeownerAliasMatch[];
}

export interface HomeownerOverrideConflict {
  project_id: string;
  term: string;
}

function normalizeRoleText(value: unknown): string {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

export function isHomeownerRoleLabel(
  value: unknown,
  trade?: unknown,
): boolean {
  const normalized = normalizeRoleText(value);
  if (!normalized) return false;
  if (normalized.includes("homeowner")) return true;
  if (normalized.includes("home owner")) return true;
  if (normalized.includes("property owner")) return true;
  if (normalized === "owner") {
    // Bare "owner" with a trade means company owner (sub/vendor), not homeowner
    const normalizedTrade = normalizeRoleText(trade);
    if (normalizedTrade) return false;
    return true;
  }
  return false;
}

export function isExplicitContradictoryProjectAnchor(
  matchType: unknown,
  term: unknown,
): boolean {
  const type = String(matchType || "").trim().toLowerCase();
  const text = String(term || "").trim();
  if (!text) return false;

  if (type === "name_match") {
    return text.length >= 4;
  }

  if (type === "alias_match") {
    const multiWord = /\s/.test(text);
    const hasDigit = /\d/.test(text);
    return multiWord || hasDigit || text.length >= 8;
  }

  return false;
}

export function findHomeownerOverrideConflict(
  homeownerProjectId: string,
  candidates: HomeownerOverrideCandidate[],
): HomeownerOverrideConflict | null {
  for (const candidate of candidates) {
    if (!candidate?.project_id || candidate.project_id === homeownerProjectId) {
      continue;
    }
    for (const match of candidate.alias_matches || []) {
      if (
        isExplicitContradictoryProjectAnchor(
          match?.match_type,
          match?.term,
        )
      ) {
        return {
          project_id: candidate.project_id,
          term: String(match?.term || "").trim(),
        };
      }
    }
  }
  return null;
}
