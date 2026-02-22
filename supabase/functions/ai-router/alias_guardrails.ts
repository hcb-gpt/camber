type Decision = "assign" | "review" | "none";

export interface AliasGuardrailAnchor {
  candidate_project_id: string | null;
  match_type: string;
  text: string;
  quote: string;
}

export interface CommonAliasGuardrailInput {
  decision: Decision;
  project_id: string | null;
  anchors: AliasGuardrailAnchor[];
}

export interface CommonAliasGuardrailResult {
  decision: Decision;
  downgraded: boolean;
  common_alias_unconfirmed: boolean;
  flagged_alias_terms: string[];
}

const STRONG_NON_ALIAS_TYPES = new Set([
  "exact_project_name",
  "address_fragment",
  "client_name",
  "chain_continuity",
]);

const PROJECT_DISAMBIGUATOR_TOKENS = new Set([
  "residence",
  "project",
  "house",
  "home",
  "site",
  "build",
  "job",
  "renovation",
  "remodel",
]);

const COLOR_TOKENS = new Set([
  "white",
  "black",
  "gray",
  "grey",
  "ivory",
  "cream",
  "beige",
  "tan",
  "taupe",
  "blue",
  "green",
  "red",
  "brown",
  "charcoal",
  "navy",
  "slate",
  "silver",
  "gold",
  "ash",
  "alabaster",
  "pearl",
]);

const MATERIAL_TOKENS = new Set([
  "marble",
  "granite",
  "quartz",
  "quartzite",
  "tile",
  "stone",
  "countertop",
  "countertops",
  "slab",
  "backsplash",
  "paint",
  "finish",
  "stain",
]);

const GENERIC_DESCRIPTOR_TOKENS = new Set([
  "mystery",
  "classic",
  "pure",
  "super",
  "premium",
  "standard",
  "signature",
  "select",
  "builder",
  "grade",
]);

const EXPLICIT_COMMON_ALIASES = new Set([
  "mystery white",
  "super white",
  "pure white",
  "classic white",
  "arctic white",
  "white quartz",
  "white marble",
  "calacatta",
  "carrara",
]);

function normalizeText(raw: string): string {
  return (raw || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[\u2018\u2019\u201C\u201D`"]/g, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function extractTokens(text: string): string[] {
  return normalizeText(text)
    .split(" ")
    .map((token) => token.trim())
    .filter((token) => token.length > 0);
}

function hasProjectDisambiguator(tokens: string[]): boolean {
  return tokens.some((token) => PROJECT_DISAMBIGUATOR_TOKENS.has(token));
}

export function isCommonWordAlias(term: string): boolean {
  const normalized = normalizeText(term);
  if (!normalized) return false;
  if (EXPLICIT_COMMON_ALIASES.has(normalized)) return true;

  const tokens = extractTokens(normalized);
  if (tokens.length === 0) return false;
  if (hasProjectDisambiguator(tokens)) return false;

  const genericTokenCount =
    tokens.filter((token) =>
      COLOR_TOKENS.has(token) || MATERIAL_TOKENS.has(token) || GENERIC_DESCRIPTOR_TOKENS.has(token)
    ).length;

  if (genericTokenCount === tokens.length && tokens.length <= 3) return true;
  if (tokens.length === 1 && (COLOR_TOKENS.has(tokens[0]) || MATERIAL_TOKENS.has(tokens[0]))) return true;

  return false;
}

function isCommonAliasAnchor(anchor: AliasGuardrailAnchor): boolean {
  const textNorm = normalizeText(anchor.text || "");
  const quoteNorm = normalizeText(anchor.quote || "");
  if (isCommonWordAlias(textNorm)) return true;
  if (!textNorm && isCommonWordAlias(quoteNorm)) return true;

  // Catch color/material references where the model extracted only the color token.
  if (COLOR_TOKENS.has(textNorm)) {
    const quoteTokens = extractTokens(quoteNorm);
    if (quoteTokens.some((token) => MATERIAL_TOKENS.has(token))) {
      return true;
    }
  }

  return false;
}

function isCorroboratingAnchor(anchor: AliasGuardrailAnchor): boolean {
  if (STRONG_NON_ALIAS_TYPES.has(anchor.match_type)) return true;
  if (anchor.match_type !== "alias") return false;
  return !isCommonAliasAnchor(anchor);
}

export function applyCommonAliasCorroborationGuardrail(
  input: CommonAliasGuardrailInput,
): CommonAliasGuardrailResult {
  const projectId = input.project_id;
  const originalDecision = input.decision;
  if (!projectId) {
    return {
      decision: originalDecision,
      downgraded: false,
      common_alias_unconfirmed: false,
      flagged_alias_terms: [],
    };
  }

  const projectAnchors = input.anchors.filter((anchor) => anchor.candidate_project_id === projectId);
  const commonAliasAnchors = projectAnchors.filter((anchor) =>
    anchor.match_type === "alias" && isCommonAliasAnchor(anchor)
  );
  if (commonAliasAnchors.length === 0) {
    return {
      decision: originalDecision,
      downgraded: false,
      common_alias_unconfirmed: false,
      flagged_alias_terms: [],
    };
  }

  const corroborated = projectAnchors.some((anchor) => isCorroboratingAnchor(anchor));
  if (corroborated) {
    return {
      decision: originalDecision,
      downgraded: false,
      common_alias_unconfirmed: false,
      flagged_alias_terms: Array.from(
        new Set(commonAliasAnchors.map((anchor) => normalizeText(anchor.text || anchor.quote || "")).filter(Boolean)),
      ),
    };
  }

  return {
    decision: originalDecision === "assign" ? "review" : originalDecision,
    downgraded: originalDecision === "assign",
    common_alias_unconfirmed: true,
    flagged_alias_terms: Array.from(
      new Set(commonAliasAnchors.map((anchor) => normalizeText(anchor.text || anchor.quote || "")).filter(Boolean)),
    ),
  };
}
