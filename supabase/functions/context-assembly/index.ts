/**
 * context-assembly Edge Function v2.2.0
 * Assembles LLM-ready context_package from span_id (SPAN-FIRST)
 *
 * @version 2.1.1
 * @date 2026-02-15
 * @purpose Provide rich context for AI Router project attribution
 * @port 6-source candidate collection from process-call v3.9.6
 *
 * CORE PRINCIPLE: span_id is the unit of truth. Calls are containers only.
 *
 * v2.1.0 Changes (Sort Order Fix — source_strength over affinity_weight):
 * - Candidate sort now prioritizes source_strength (transcript evidence quality)
 *   ABOVE affinity_weight (call-history frequency)
 * - Fixes Permar-class bug where high-affinity projects with weak transcript evidence
 *   outranked low-affinity projects with strong evidence (e.g., source_strength +1.22)
 * - Sort order: assigned > weak_only > alias_matches > source_strength > affinity > geo
 *
 * v2.2.0 Changes (Client Override Gate):
 * - NEW: Queries project_clients table as a candidate source in SOURCE 1
 * - NEW: Client override gate mirrors homeowner override — if a unique client-linked
 *   project exists, force it (unless homeowner override already applied).
 * - Same contradictory-anchor escape hatch as homeowner override.
 * - Emits meta.client_override* fields for downstream traceability.
 *
 * v2.1.1 Changes (P0 Homeowner Override Gate):
 * - If a unique homeowner project link exists in project_contacts, deterministically
 *   constrain candidates to that project.
 * - Escape hatch: do not force override when transcript shows explicit contradictory
 *   project anchors (name/strong alias) for another project.
 * - Emits meta.homeowner_override* fields for downstream traceability.
 *
 * v2.0.0 Changes (4 New Candidate Sources + Floater Modifier):
 * - NEW Source 9: OTHER_PARTY_TRADE_MATCH — parse speaker names, match contacts, find trade→projects
 * - NEW Source 10: CROSS_CONTACT_CLAIM_MATCH — unscoped journal keyword search across all contacts
 * - NEW Source 11: MATERIAL_BUDGET_TIER_MATCH — material keywords → budget tier → project contract_value
 * - NEW Source 12: STRUCTURAL_TYPE_MATCH — structural keywords → foundation_type → project_building_specs
 * - NEW Floater modifier: when is_internal=true AND floater_flag=true:
 *     - Halve affinity weights (Sources 2-3) via FLOATER_AFFINITY_DISCOUNT
 *     - Expand MAX_CANDIDATES from 8 to 12
 *     - Unscope journal context (remove contact_id filter for claims/loops)
 *
 * v1.9.0 Changes (AI-ready Geo Signal Enrichment):
 * - NEW: Candidate evidence now includes geo_signal summary:
 *   { score, dominant_role, role_counts, place_count }
 * - NEW: Geo scoring stays weak by design (never sufficient for auto-assign)
 * - NEW: Role-aware geo aggregation (destination/origin/proximity) per project
 *
 * v1.8.0 Changes (Journal Context Poisoning Fix):
 * - NEW: journal claims/loops are contact-scoped (same contact_id OR same phone)
 * - NEW: null-contact calls skip journal context entirely to avoid unanchored leakage
 *
 * v1.5.0 Changes (Contact Fanout Integration — DATA-9 D4 spec):
 * - REPLACED: contacts.floats_between_projects boolean → contact_fanout table lookup
 * - NEW: context_package.contact.fanout_class (anchored|semi_anchored|drifter|floater|unknown)
 * - NEW: context_package.contact.effective_fanout (integer project count)
 * - PRESERVED: floater_flag for backwards compat (derived from fanout_class)
 *
 * v1.7.0 Changes (Continuity Bundle):
 * - NEW: continuity_links array linking back-to-back calls within 48h
 * - Tiered evidence (project mention, callback phrase, recency) with floater rule
 *
 * v1.6.0 Changes (Gmail Context Lookup):
 * - NEW: calls gmail-context-lookup edge function (bounded, fail-open)
 * - NEW: context_package.email_context (bounded metadata, no free-text snippets)
 * - NEW: context_package.email_lookup_meta (receipt-friendly lookup metadata)
 *
 * v1.4.0 Changes (Journal/World Model integration):
 * - NEW: journal-derived project state injected into context package
 * - For each candidate project, fetches active journal_claims and open_loops
 * - New field: context_package.project_journal (per-project state summaries)
 *
 * v1.2.0 Changes (PR-7 Phase 2: Enroute Detection):
 * - VERB-DRIVEN role tagging: destination/origin/proximity
 * - Inserts detected place mentions into span_place_mentions
 * - POLICY (STRAT-1 BLOCK): Role is ONLY assigned via explicit verbs
 * - Single place without verb = "proximity" (NEVER inferred direction)
 *
 * v1.1.0 Changes (PR-7: Geo Candidate Assist):
 * - SOURCE 7: geo proximity candidates from project_geo + geo_places
 * - Geo is a WEAK signal only (source='geo_proximity')
 * - Never sufficient for auto-assign; adds nearby projects as candidates
 *
 * Input:
 *   - span_id: string (required) - PRIMARY key for context assembly
 *   - interaction_id + span_index: (debug convenience) - resolves to span_id first
 *
 * Output:
 *   - context_package JSON with meta, span, contact, candidates, place_mentions, project_journal,
 *     email_context, email_lookup_meta
 *
 * AUTH:
 * - Accepts service role JWT (verify_jwt=false in config)
 * - Also accepts X-Edge-Secret for internal function-to-function calls
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { validateEdgeSecret } from "../_shared/auth.ts";
import { computeClaimCrossref } from "./claim_crossref.ts";
import { findHomeownerOverrideConflict, isHomeownerRoleLabel } from "./homeowner_override.ts";

const ASSEMBLY_VERSION = "v2.2.0"; // v2.2.0: client override gate + project_clients source
const SELECTION_RULES_VERSION = "v1.0.0";
const MAX_CANDIDATES = 8;
const MAX_CANDIDATES_FLOATER = 12; // Expanded for internal floater contacts
const MAX_TRANSCRIPT_CHARS = 8000;
const MAX_ALIAS_TERMS_PER_PROJECT = 25;
const GMAIL_LOOKUP_DEFAULT_LOOKBACK_DAYS = 30;
const GMAIL_LOOKUP_DEFAULT_MAX_RESULTS = 5;
const GMAIL_LOOKUP_TIMEOUT_MS = 8000;

// Geo candidate constants
const GEO_MAX_DISTANCE_KM = 50; // Only consider projects within 50km
const GEO_MAX_CANDIDATES = 5; // Cap geo candidates to prevent flooding

// Continuity bundle constants
const CONTINUITY_LOOKBACK_HOURS = 48;
const CONTINUITY_MAX_PRIOR_CALLS = 5;
const CONTINUITY_FLOATER_GAP_HOURS = 4;
const CALLBACK_PHRASES = [
  "calling you back",
  "returning your call",
  "missed your call",
  "following up",
  "as we discussed",
  "like we talked about",
];

// =========================
// SOURCE STRENGTH CALIBRATION
// =========================
const SOURCE_SCORE_GMAIL_CONTENT_MATCH = 0.45;
const SOURCE_SCORE_MATERIAL_STRUCTURAL_BASE = 0.08;
const SOURCE_SCORE_MATERIAL_STRUCTURAL_MAX = 0.45;
const SOURCE_SCORE_CLAIM_CONTENT_MATCH_PER_SIGNAL = 0.35;
const SOURCE_SCORE_OTHER_PARTY_TRADE_MATCH = 0.18;
const SOURCE_SCORE_PROJECT_CONTACT = 0.22;
const SOURCE_SCORE_FLOATER_ANTI_SIGNAL = -0.28;
const SOURCE_SCORE_CROSS_CONTACT_CLAIM_MATCH = 0.20; // Source 10: unscoped claim keyword match (lower than contact-scoped)
const SOURCE_SCORE_MATERIAL_BUDGET_TIER = 0.40; // Source 11: material→budget tier→project match
const SOURCE_SCORE_STRUCTURAL_TYPE_SINGLE = 0.50; // Source 12: structural type match (unique match)
const SOURCE_SCORE_STRUCTURAL_TYPE_MULTI = 0.30; // Source 12: structural type match (multiple matches)
const SOURCE_SCORE_COMMON_WORD_ALIAS_DEMOTION = 0.65; // Common-word alias demotion (e.g., "mystery white")
const SOURCE_SCORE_HOMEOWNER_OVERRIDE = 1.25; // Deterministic owner-contact constraint signal
const FLOATER_AFFINITY_DISCOUNT = 0.5; // Floater modifier: halve affinity weights for sources 2-3
const COMMON_WORD_ALIAS_TERMS = new Set(["white"]);
const CROSS_CONTACT_MAX_SEARCH_TERMS = 20;
const CROSS_CONTACT_MAX_LIKE_PATTERNS = 24;
const CROSS_CONTACT_MIN_SEARCH_TERMS = 2;
const CROSS_CONTACT_EVIDENCE_TERM_LIMIT = 5;
const CLAIM_CONTENT_EVIDENCE_TERM_LIMIT = 5;
const MATERIAL_BUDGET_EVIDENCE_TERM_LIMIT = 5;
const CROSS_CONTACT_LOW_SIGNAL_COLORS = new Set([
  "white",
  "black",
  "gray",
  "grey",
  "beige",
  "cream",
  "brown",
  "blue",
  "green",
  "red",
  "gold",
  "silver",
  "tan",
]);
const CROSS_CONTACT_LOW_SIGNAL_DESCRIPTORS = new Set([
  "mystery",
  "classic",
  "pure",
  "standard",
  "basic",
  "regular",
  "normal",
  "general",
  "default",
  "common",
  "simple",
]);
const CROSS_CONTACT_LOW_SIGNAL_MATERIALS = new Set([
  "tile",
  "paint",
  "stone",
  "marble",
  "granite",
  "quartz",
  "wood",
  "vinyl",
  "glass",
]);
const CROSS_CONTACT_LOW_SIGNAL_DISAMBIGUATORS = new Set([
  "residence",
  "house",
  "home",
  "site",
  "job",
  "project",
  "property",
  "build",
  "location",
]);
const CROSS_CONTACT_FIXTURE_TERMS = new Set([
  "fixture",
  "fixtures",
  "window",
  "windows",
  "door",
  "doors",
  "cabinet",
  "cabinets",
  "vanity",
  "vanities",
  "sink",
  "sinks",
  "toilet",
  "toilets",
  "shower",
  "showers",
  "countertop",
  "countertops",
  "island",
  "islands",
]);
const CROSS_CONTACT_STREET_SUFFIXES = new Set([
  "st",
  "street",
  "ave",
  "avenue",
  "blvd",
  "boulevard",
  "rd",
  "road",
  "dr",
  "drive",
  "ln",
  "lane",
  "ct",
  "court",
  "cir",
  "circle",
  "pl",
  "place",
  "way",
  "pkwy",
  "parkway",
]);
const MATERIAL_BUDGET_LOW_SIGNAL_KEYWORDS = new Set([
  "white",
  "black",
  "gray",
  "grey",
  "beige",
  "cream",
  "tile",
  "paint",
  "stone",
  "material",
  "home",
  "house",
  "residence",
  "project",
  "job",
  "site",
  "mystery",
  "classic",
  "pure",
]);
const LOW_SIGNAL_COMMON_TOKENS = new Set([
  "the",
  "this",
  "that",
  "these",
  "those",
  "there",
  "here",
  "with",
  "from",
  "into",
  "onto",
  "only",
  "just",
  "like",
  "okay",
  "yeah",
  "yep",
  "got",
  "get",
  "have",
  "has",
  "had",
  "then",
  "than",
  "when",
  "what",
  "where",
  "which",
  "about",
  "around",
  "over",
  "under",
  "after",
  "before",
  "customer",
  "doesn",
  "dont",
  "didn",
  "new",
]);

// Structural keywords → foundation_type mapping
const STRUCTURAL_KEYWORD_MAP: Record<string, string> = {
  "slab house": "slab",
  "slab on grade": "slab",
  "slab foundation": "slab",
  "basement": "basement",
  "full basement": "basement",
  "walk out basement": "basement",
  "walkout basement": "basement",
  "crawl space": "crawl",
  "crawlspace": "crawl",
  "crawl": "crawl",
  "pier foundation": "pier",
  "pier and beam": "pier",
};

// Budget tier midpoints for contract_value matching
const TIER_MIDPOINTS: Record<string, number> = {
  premium: 1500000,
  mid_range: 900000,
  budget: 600000,
};

// PR-11: Project status filter - only include active client projects
const VALID_PROJECT_STATUSES = ["active", "warranty", "estimating"];
// PR-11 (STRAT TURN14): Filter by project_kind to exclude internal/owner projects
const VALID_PROJECT_KIND = "client";

// ============================================================
// ADMIN ALLOWLIST (PR-10 hardening)
// Hard-coded admin user IDs as second-layer gate
// REQUIRED: At least one of ADMIN_USER_IDS or ALLOWED_EMAILS must match
// ============================================================
const ADMIN_USER_IDS: string[] = [
  // Add Supabase auth.users.id values here
  // Example: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
];

// ============================================================
// ENROUTE VERB PATTERNS (STRAT-1 POLICY: VERB-DRIVEN ONLY)
// ============================================================
// POLICY: Role tagging is DETERMINISTIC and VERB-DRIVEN
// - "destination" requires explicit destination verbs
// - "origin" requires explicit origin verbs
// - Single place mention WITHOUT verb = "proximity" (NO direction inferred)
// - NEVER infer direction from a single place without explicit verb

const DESTINATION_VERBS = [
  "headed to",
  "heading to",
  "going to",
  "on my way to",
  "on the way to",
  "driving to",
  "heading over to",
  "headed over to",
  "going over to",
  "en route to",
  "enroute to",
];

const ORIGIN_VERBS = [
  "coming from",
  "came from",
  "leaving",
  "left from",
  "left",
  "back from",
  "returning from",
  "just left",
  "driving from",
  "on my way from",
];

// ============================================================
// TYPES
// ============================================================

interface AliasMatch {
  term: string;
  match_type: string;
  snippet?: string;
}

type PlaceRole = "proximity" | "origin" | "destination";

interface GeoSignal {
  // Weak signal score (0.05-0.55): useful for AI tie-breaking, never for solo auto-assign.
  score: number;
  dominant_role: PlaceRole;
  role_counts: Record<PlaceRole, number>;
  place_count: number;
}

interface CandidateEvidence {
  sources: string[];
  affinity_weight: number;
  assigned: boolean;
  alias_matches: AliasMatch[];
  geo_distance_km?: number;
  geo_signal?: GeoSignal;
  source_scores?: Record<string, number>;
  source_strength?: number;
  claim_crossref_score?: number;
  claim_crossref_topics?: string[];
  claim_crossref_snippets?: string[];
  claim_content_match_terms?: string[];
  cross_contact_claim_match_terms?: string[];
  material_budget_tier_terms?: string[];
  weak_only?: boolean; // true if ALL alias evidence is weak (first-name-only, short token)
  common_word_alias_demoted?: boolean;
  corroboration_count?: number; // v2.3.0: count of independent evidence categories
}

interface Candidate {
  project_id: string;
  project_name: string;
  address: string | null;
  client_name: string | null;
  aliases: string[];
  status: string | null;
  phase: string | null;
  evidence: CandidateEvidence;
}

interface RecentProject {
  project_id: string;
  project_name: string;
  last_seen: string | null;
}

interface PlaceMention {
  place_name: string;
  geo_place_id: string | null;
  lat: number | null;
  lon: number | null;
  role: PlaceRole;
  trigger_verb: string | null;
  char_offset: number;
  snippet: string;
}

// v1.4.0: Journal-derived project state
interface JournalClaim {
  claim_type: string;
  claim_text: string;
  epistemic_status: string;
  created_at: string;
}

interface JournalOpenLoop {
  loop_type: string;
  description: string;
  status: string;
}

interface ProjectJournalState {
  project_id: string;
  active_claims_count: number;
  recent_claims: JournalClaim[]; // Last 5 active claims
  open_loops: JournalOpenLoop[]; // Open loops for this project
  last_journal_activity: string | null; // Timestamp of most recent claim
}

// v2.2.0: World model facts (time-aware, provenance-backed)
interface ProjectFactRow {
  project_id: string;
  as_of_at: string;
  observed_at: string;
  fact_kind: string;
  fact_payload: any;
  evidence_event_id: string | null;
  interaction_id: string | null;
}

interface ProjectFactsPack {
  project_id: string;
  facts: ProjectFactRow[];
}

interface EmailContextItem {
  message_id: string;
  thread_id: string | null;
  date: string | null;
  from: string | null;
  to: string | null;
  subject: string | null;
  subject_keywords: string[];
  project_mentions: string[];
  mentioned_project_ids: string[];
  amounts_mentioned: string[];
  evidence_locator: string;
}

interface EmailLookupMeta {
  step: string;
  source: string | null;
  contact_id: string | null;
  query: string | null;
  date_range: string | null;
  results_count: number;
  returned_count: number;
  cached: boolean;
  lookup_ms: number | null;
  gmail_api_calls: number;
  auth_mode: string | null;
  warnings: string[];
  truncation: string[];
}

interface ContextPackage {
  meta: {
    assembly_version: string;
    selection_rules_version: string;
    span_id: string;
    interaction_id: string;
    assembled_at_utc: string;
    truncations: string[];
    warnings: string[];
    sources_used: string[];
    homeowner_override: boolean;
    homeowner_override_project_id: string | null;
    homeowner_override_conflict_project_id: string | null;
    homeowner_override_conflict_term: string | null;
    homeowner_override_skipped_reason: string | null;
    client_override: boolean;
    client_override_project_id: string | null;
    client_override_conflict_project_id: string | null;
    client_override_conflict_term: string | null;
    client_override_skipped_reason: string | null;
  };
  span: {
    start_ms: number | null;
    end_ms: number | null;
    transcript_text: string;
    words?: any[];
  };
  contact: {
    contact_id: string | null;
    contact_name: string | null;
    phone_e164_last4: string | null;
    floater_flag: boolean; // Backwards compat: derived from fanout_class
    fanout_class: string; // v1.5.0: anchored|semi_anchored|drifter|floater|unknown
    effective_fanout: number; // v1.5.0: number of active projects
    recent_projects: RecentProject[];
  };
  candidates: Candidate[];
  place_mentions: PlaceMention[];
  project_journal: ProjectJournalState[]; // v1.4.0: journal-derived state per candidate project
  project_facts?: ProjectFactsPack[]; // v2.2.0: optional world model facts per candidate project
  email_context: EmailContextItem[];
  email_lookup_meta: EmailLookupMeta | null;
  continuity_links: ContinuityLink[];
}

interface ContinuityLink {
  prior_interaction_id: string;
  prior_project_id: string | null;
  prior_project_name: string | null;
  prior_event_at_utc: string | null;
  gap_minutes: number;
  tier: "TIER_1" | "TIER_2" | "TIER_3";
  evidence: {
    reason: string;
    spans: string[];
    callback_phrase_hits: string[];
  };
}

// ============================================================
// UTILITIES
// ============================================================

/** Strip speaker labels from transcript to avoid false alias matches */
function stripSpeakerLabels(text: string): string {
  return (text || "").replace(/(^|\n)\s*[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\s*:/g, "$1");
}

/** Word-boundary-aware term search - scans ALL occurrences, not just first */
function findTermInText(textLower: string, termLower: string): number {
  const isWordChar = (ch: string) => /[a-z0-9]/i.test(ch);
  let startPos = 0;
  while (startPos < textLower.length) {
    const idx = textLower.indexOf(termLower, startPos);
    if (idx < 0) return -1;
    const before = idx === 0 ? " " : textLower[idx - 1];
    const afterIdx = idx + termLower.length;
    const after = afterIdx >= textLower.length ? " " : textLower[afterIdx];
    if (
      !isWordChar(before) && !isWordChar(after) &&
      before !== "'" && before !== "\u2019" &&
      after !== "'" && after !== "\u2019"
    ) {
      return idx;
    }
    // Handle possessive 's / \u2019s — treat as valid word boundary
    if (!isWordChar(before) && (after === "'" || after === "\u2019")) {
      const nextIdx = afterIdx + 1;
      if (
        nextIdx < textLower.length &&
        textLower[nextIdx].toLowerCase() === "s"
      ) {
        const afterS = nextIdx + 1;
        if (afterS >= textLower.length || !isWordChar(textLower[afterS])) {
          return idx; // possessive — valid match
        }
      }
    }
    startPos = idx + 1;
  }
  return -1;
}

function normalizeTradeLabel(value: string | null | undefined): string {
  return (value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

function clamp(num: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, num));
}

function parseBoolEnv(key: string, defaultValue = false): boolean {
  const raw = (Deno.env.get(key) || "").trim().toLowerCase();
  if (!raw) return defaultValue;
  return raw === "1" || raw === "true" || raw === "yes" || raw === "y";
}

const WORLD_MODEL_FACTS_ENABLED = parseBoolEnv("WORLD_MODEL_FACTS_ENABLED", false);
const WORLD_MODEL_FACTS_MAX_PER_PROJECT = clamp(
  Number.parseInt(Deno.env.get("WORLD_MODEL_FACTS_MAX_PER_PROJECT") || "20", 10) || 20,
  0,
  50,
);
const DISABLE_INTERACTION_PROJECT_ID_FALLBACKS = parseBoolEnv(
  "DISABLE_INTERACTION_PROJECT_ID_FALLBACKS",
  false,
);

function tokenizeTextForOverlap(text: string): string[] {
  return (text || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .split(/\s+/)
    .filter((t) => t.length >= 4 || (t.length >= 3 && !/^\d+$/.test(t)))
    .filter(Boolean);
}

function overlappingTokenTerms(leftTokens: string[], rightTokens: string[]): string[] {
  const leftSet = new Set(leftTokens.map((t) => t.toLowerCase()).filter(Boolean));
  const overlap: string[] = [];
  const seen = new Set<string>();
  for (const tok of rightTokens.map((t) => t.toLowerCase()).filter(Boolean)) {
    if (!seen.has(tok) && leftSet.has(tok)) {
      overlap.push(tok);
      seen.add(tok);
    }
  }
  return overlap;
}

function sanitizeCrossContactTerm(raw: string): string {
  return (raw || "")
    .toLowerCase()
    .replace(/[%(),]/g, " ")
    .replace(/[^a-z0-9$ ]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isLowSignalCrossContactToken(token: string): boolean {
  return CROSS_CONTACT_LOW_SIGNAL_COLORS.has(token) ||
    CROSS_CONTACT_LOW_SIGNAL_DESCRIPTORS.has(token) ||
    CROSS_CONTACT_LOW_SIGNAL_MATERIALS.has(token) ||
    CROSS_CONTACT_LOW_SIGNAL_DISAMBIGUATORS.has(token);
}

function isLowSignalLexeme(rawToken: string): boolean {
  const token = sanitizeCrossContactTerm(rawToken);
  if (!token) return true;
  return LOW_SIGNAL_COMMON_TOKENS.has(token) ||
    isLowSignalCrossContactToken(token) ||
    MATERIAL_BUDGET_LOW_SIGNAL_KEYWORDS.has(token);
}

function isLowSignalMaterialBudgetKeyword(rawKeyword: string): boolean {
  const keyword = sanitizeCrossContactTerm(rawKeyword);
  if (!keyword) return true;
  const tokens = keyword.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return true;

  const isLowSignalToken = (token: string) => isLowSignalLexeme(token);

  if (tokens.length === 1) {
    const token = tokens[0];
    if (isLowSignalToken(token)) return true;
  }

  return tokens.every((token) => isLowSignalToken(token));
}

function isAddressLikeCrossContactTerm(term: string): boolean {
  const tokens = term.split(/\s+/).filter(Boolean);
  if (tokens.length < 2) return false;
  return /\d/.test(tokens[0]) && CROSS_CONTACT_STREET_SUFFIXES.has(tokens[tokens.length - 1]);
}

function addCrossContactTerm(termScores: Map<string, number>, rawTerm: string, score: number): void {
  const term = sanitizeCrossContactTerm(rawTerm);
  if (!term) return;
  const tokens = term.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return;

  const hasDigits = /\d/.test(term);
  const isDollar = term.startsWith("$");
  const addressLike = isAddressLikeCrossContactTerm(term);

  if (tokens.length === 1 && !hasDigits && !isDollar) {
    const token = tokens[0];
    if (token.length < 5) return;
    if (isLowSignalCrossContactToken(token)) return;
  } else if (!hasDigits && !isDollar && !addressLike) {
    const allLowSignal = tokens.every((token) => isLowSignalCrossContactToken(token));
    if (allLowSignal) return;
  }

  const current = termScores.get(term) || 0;
  if (score > current) termScores.set(term, score);
}

function extractCapitalizedCrossContactTerms(text: string): string[] {
  const words = text.split(/\s+/);
  const terms = new Set<string>();
  for (let i = 0; i < words.length; i++) {
    const current = words[i].replace(/^[^A-Za-z0-9$]+|[^A-Za-z0-9$]+$/g, "");
    if (!current) continue;

    const prev = i > 0 ? words[i - 1] : "";
    const sentenceStart = i === 0 || /[.!?]$/.test(prev);
    const next = i + 1 < words.length ? words[i + 1].replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, "") : "";
    const nextCap = /^[A-Z][a-z]{2,}$/.test(next);

    if (/^[A-Z][a-z]{2,}$/.test(current)) {
      if (!sentenceStart || nextCap) {
        terms.add(current.toLowerCase());
      }
      if (nextCap) {
        terms.add(`${current.toLowerCase()} ${next.toLowerCase()}`);
        const nextNext = i + 2 < words.length ? words[i + 2].replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, "") : "";
        if (/^[A-Z][a-z]{2,}$/.test(nextNext)) {
          terms.add(`${current.toLowerCase()} ${next.toLowerCase()} ${nextNext.toLowerCase()}`);
        }
      }
      continue;
    }

    if (/^[A-Z]{3,8}$/.test(current)) {
      terms.add(current.toLowerCase());
    }
  }
  return Array.from(terms);
}

function crossContactFuzzyTokenVariants(token: string): string[] {
  const normalized = sanitizeCrossContactTerm(token);
  const variants = new Set<string>([normalized]);
  if (!/^[a-z]+$/.test(normalized) || normalized.length < 6) {
    return Array.from(variants);
  }

  if (normalized.startsWith("wind")) {
    variants.add(`win${normalized.slice(4)}`);
  } else if (normalized.startsWith("win")) {
    variants.add(`wind${normalized.slice(3)}`);
  }

  if (normalized.includes("dsh")) {
    variants.add(normalized.replace(/dsh/g, "sh"));
  }
  if (normalized.includes("ndsh")) {
    variants.add(normalized.replace(/ndsh/g, "nsh"));
  }

  return Array.from(variants);
}

function extractHighSignalCrossContactTerms(transcript: string): string[] {
  const termScores = new Map<string, number>();

  const addressRegex =
    /\b\d{2,6}\s+[A-Za-z0-9'.-]+(?:\s+[A-Za-z0-9'.-]+){0,3}\s+(?:st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|way|pkwy|parkway)\b/gi;
  let match: RegExpExecArray | null;
  while ((match = addressRegex.exec(transcript)) !== null) {
    addCrossContactTerm(termScores, match[0], 100);
  }

  const dollarRegex =
    /\$\s?\d[\d,]*(?:\.\d+)?(?:\s*(?:k|m|mm|thousand|million))?|\b\d[\d,]*(?:\.\d+)?\s*(?:dollars?|bucks?)\b/gi;
  while ((match = dollarRegex.exec(transcript)) !== null) {
    addCrossContactTerm(termScores, match[0].replace(/\s+/g, ""), 95);
  }

  const qtyFixtureRegex =
    /\b(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:fixture|fixtures|window|windows|door|doors|cabinet|cabinets|vanity|vanities|sink|sinks|toilet|toilets|shower|showers|countertop|countertops|island|islands)\b/gi;
  while ((match = qtyFixtureRegex.exec(transcript)) !== null) {
    addCrossContactTerm(termScores, match[0], 90);
  }

  for (const properTerm of extractCapitalizedCrossContactTerms(transcript)) {
    addCrossContactTerm(termScores, properTerm, properTerm.includes(" ") ? 88 : 84);
  }

  const modelRegex = /\b[a-zA-Z]*\d+[a-zA-Z0-9-]*\b/g;
  while ((match = modelRegex.exec(transcript)) !== null) {
    addCrossContactTerm(termScores, match[0], 82);
  }

  for (const token of tokenizeTextForOverlap(transcript)) {
    const normalized = sanitizeCrossContactTerm(token);
    if (!normalized || normalized.length < 6) continue;
    if (isLowSignalCrossContactToken(normalized)) continue;
    addCrossContactTerm(termScores, normalized, 72);
    if (CROSS_CONTACT_FIXTURE_TERMS.has(normalized)) {
      addCrossContactTerm(termScores, normalized, 85);
    }
  }

  return Array.from(termScores.entries())
    .sort((a, b) => b[1] - a[1] || b[0].length - a[0].length)
    .map(([term]) => term)
    .slice(0, CROSS_CONTACT_MAX_SEARCH_TERMS);
}

function buildCrossContactSearchTerms(highSignalTerms: string[]): string[] {
  const searchTerms: string[] = [];
  const seen = new Set<string>();
  const pushTerm = (raw: string) => {
    const term = sanitizeCrossContactTerm(raw);
    if (!term || seen.has(term)) return;
    seen.add(term);
    searchTerms.push(term);
  };

  for (const term of highSignalTerms) {
    pushTerm(term);
    if (!term.includes(" ")) {
      for (const fuzzyVariant of crossContactFuzzyTokenVariants(term)) {
        pushTerm(fuzzyVariant);
      }
    }
    if (searchTerms.length >= CROSS_CONTACT_MAX_LIKE_PATTERNS) break;
  }

  return searchTerms.slice(0, CROSS_CONTACT_MAX_LIKE_PATTERNS);
}

/** Normalize alias terms (dedupe, min length) */
function normalizeAliasTerms(terms: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const t0 of terms) {
    const t = (t0 || "").trim();
    if (!t) continue;
    const low = t.toLowerCase();
    if (seen.has(low)) continue;
    if (low.length < 4) continue;
    seen.add(low);
    out.push(t);
  }
  return out;
}

/** v2.3.0: Count independent evidence categories for corroboration scoring.
 *  Maps raw source strings to categories so that e.g. two transcript sources count as 1. */
function countCorroborationCategories(sources: string[], assigned: boolean, hasGeoSignal: boolean): number {
  const categories = new Set<string>();
  for (const src of sources) {
    if (src === "rpc_scan_transcript_for_projects" || src === "fts_transcript_match") {
      categories.add("transcript");
    } else if (src === "correspondent_project_affinity") {
      categories.add("affinity");
    } else if (src === "cross_contact_claim_match" || src === "claim_content_match") {
      categories.add("claim");
    } else if (src === "geo_proximity") {
      categories.add("geo");
    } else if (src === "interactions_existing_project") {
      categories.add("assignment");
    } else if (src === "material_budget_tier_match") {
      categories.add("material");
    } else if (src === "world_model_project_facts") {
      categories.add("world_model");
    } else {
      categories.add(src); // unknown source gets its own category
    }
  }
  if (assigned && !categories.has("assignment")) categories.add("assignment");
  if (hasGeoSignal && !categories.has("geo")) categories.add("geo");
  return categories.size;
}

/** PHONETIC-ADJACENT-ONLY: Classify whether an alias match is strong or weak.
 *  - "strong": exact project name, explicit address fragment, multi-word alias, last-name match
 *  - "weak": single short first-name-only token with no corroboration */
function classifyMatchStrength(
  term: string,
  matchType: string,
  projectName: string,
): "strong" | "weak" {
  const termLower = term.toLowerCase();
  const nameLower = projectName.toLowerCase();

  // Exact project name match is always strong
  if (termLower === nameLower || matchType === "exact_project_name" || matchType === "name_match") return "strong";

  const isExplicitAddress = /\d/.test(termLower) ||
    /\b(?:st|street|ave|avenue|blvd|boulevard|rd|road|dr|drive|ln|lane|ct|court|cir|circle|pl|place|pkwy|parkway|way)\b/
      .test(termLower);

  // Location matches are weak (city-only corroboration) unless explicitly address-like
  if (matchType === "city_or_location" || matchType === "location_match") {
    if (isExplicitAddress) return "strong";
    return "weak";
  }

  // Multi-word terms are strong (full name, addresses, etc.)
  if (term.trim().includes(" ")) return "strong";

  // Check if this is a last-name component match (strong)
  const nameParts = nameLower.split(/\s+/);
  if (nameParts.length >= 2) {
    const lastName = nameParts[nameParts.length - 1];
    if (termLower === lastName) return "strong";
  }

  // Single-word alias match >= 6 chars is strong (distinctive enough)
  if (term.length >= 6 && (matchType === "alias" || matchType === "alias_match")) return "strong";

  // Everything else (short single-word, first-name-only, db_scan short tokens) = weak
  return "weak";
}

/** Extract snippet around a match position */
function snippetAround(text: string, idx: number, termLen: number, radius = 40): string {
  if (!text || idx < 0) return "";
  const start = Math.max(0, idx - radius);
  const end = Math.min(text.length, idx + termLen + radius);
  let snippet = text.slice(start, end).replace(/\s+/g, " ").trim();
  if (start > 0) snippet = "..." + snippet;
  if (end < text.length) snippet = snippet + "...";
  return snippet.slice(0, 100);
}

function normalizePhone(phone: string | null | undefined): string | null {
  const digits = (phone || "").replace(/\D/g, "");
  if (!digits) return null;
  if (digits.length === 11 && digits.startsWith("1")) return digits.slice(1);
  if (digits.length > 10) return digits.slice(-10);
  return digits;
}

function matchesJournalSourceContact(
  currentContactId: string | null,
  currentPhone: string | null,
  sourceContactId: string | null | undefined,
  sourcePhone: string | null | undefined,
): boolean {
  if (currentContactId && sourceContactId && currentContactId === sourceContactId) {
    return true;
  }
  const cur = normalizePhone(currentPhone);
  const src = normalizePhone(sourcePhone);
  if (!cur || !src) return false;
  return cur === src || cur.slice(-4) === src.slice(-4);
}

/** Smart truncation: window around evidence to preserve anchors */
function smartTruncate(
  transcript: string,
  matchPositions: number[],
  maxChars: number,
): { text: string; truncated: boolean } {
  if (transcript.length <= maxChars) {
    return { text: transcript, truncated: false };
  }

  if (matchPositions.length === 0) {
    return { text: transcript.slice(0, maxChars) + "...", truncated: true };
  }

  const firstMatch = Math.min(...matchPositions);
  const lastMatch = Math.max(...matchPositions);
  const matchSpan = lastMatch - firstMatch;
  const windowStart = Math.max(0, firstMatch - Math.floor((maxChars - matchSpan) / 2));
  const windowEnd = Math.min(transcript.length, windowStart + maxChars);

  let text = transcript.slice(windowStart, windowEnd);
  if (windowStart > 0) text = "..." + text;
  if (windowEnd < transcript.length) text = text + "...";

  return { text, truncated: true };
}

/** Haversine distance in km between two lat/lon points */
function haversineDistanceKm(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6371;
  const toRad = (deg: number) => deg * Math.PI / 180;

  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);

  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLon / 2) ** 2;

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function emptyRoleCounts(): Record<PlaceRole, number> {
  return { proximity: 0, origin: 0, destination: 0 };
}

function dominantRoleFromCounts(counts: Record<PlaceRole, number>): PlaceRole {
  const destination = counts.destination || 0;
  const origin = counts.origin || 0;
  const proximity = counts.proximity || 0;

  // Tie-break policy prefers directional roles over proximity.
  if (destination >= origin && destination >= proximity) return "destination";
  if (origin >= destination && origin >= proximity) return "origin";
  return "proximity";
}

function computeGeoWeakScore(
  minDistanceKm: number,
  roleCounts: Record<PlaceRole, number>,
  placeCount: number,
): number {
  // Base distance signal: 0..0.35 across the 50km window.
  const normalizedDistance = Math.max(0, Math.min(1, 1 - (minDistanceKm / GEO_MAX_DISTANCE_KM)));
  const distanceScore = normalizedDistance * 0.35;

  // Directional phrasing adds weak corroboration, never enough to stand alone.
  const directionalHits = (roleCounts.destination || 0) + (roleCounts.origin || 0);
  const roleBoost = directionalHits > 0 ? 0.12 : 0;

  // Multiple distinct place mentions can reinforce confidence slightly.
  const placeBoost = Math.min(0.08, Math.max(0, placeCount - 1) * 0.02);

  // Always keep geo in weak band.
  const raw = 0.05 + distanceScore + roleBoost + placeBoost;
  return Math.max(0.05, Math.min(0.55, raw));
}

/** Find callback phrases and return snippets (<=80 chars) around them */
function findCallbackPhraseSpans(
  transcript: string,
  transcriptLower: string,
): string[] {
  const spans: string[] = [];
  for (const phrase of CALLBACK_PHRASES) {
    const phraseLower = phrase.toLowerCase();
    const idx = transcriptLower.indexOf(phraseLower);
    if (idx >= 0) {
      const snippet = snippetAround(transcript, idx, phrase.length, 60).slice(0, 80);
      spans.push(snippet);
      if (spans.length >= 5) break;
    }
  }
  return spans;
}

/**
 * VERB-DRIVEN ROLE DETECTION
 * POLICY (STRAT-1 BLOCK):
 * - Role is ONLY assigned via explicit verbs
 * - Single place without verb = "proximity"
 * - NEVER infer direction from a single place
 *
 * @param transcriptLower - Lowercased transcript
 * @param placeIdx - Character index of place mention
 * @param placeName - Name of the place
 * @returns { role, trigger_verb } - Role and the verb that triggered it
 */
function detectPlaceRole(
  transcriptLower: string,
  placeIdx: number,
  placeName: string,
): { role: PlaceRole; trigger_verb: string | null } {
  // Look in a window before the place mention for verb patterns
  const VERB_WINDOW = 60; // Characters before place to search for verbs
  const windowStart = Math.max(0, placeIdx - VERB_WINDOW);
  const windowText = transcriptLower.slice(windowStart, placeIdx + placeName.length);

  // Check destination verbs first (more specific patterns)
  for (const verb of DESTINATION_VERBS) {
    const verbIdx = windowText.indexOf(verb);
    if (verbIdx >= 0) {
      // Verify verb appears BEFORE the place (not after)
      const verbEndPos = windowStart + verbIdx + verb.length;
      if (verbEndPos <= placeIdx + 5) { // Allow small gap
        return { role: "destination", trigger_verb: verb };
      }
    }
  }

  // Check origin verbs
  for (const verb of ORIGIN_VERBS) {
    const verbIdx = windowText.indexOf(verb);
    if (verbIdx >= 0) {
      const verbEndPos = windowStart + verbIdx + verb.length;
      if (verbEndPos <= placeIdx + 5) {
        return { role: "origin", trigger_verb: verb };
      }
    }
  }

  // No verb found = proximity only (NEVER infer direction)
  return { role: "proximity", trigger_verb: null };
}

// ============================================================
// MAIN HANDLER
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        ok: false,
        error_code: "method_not_allowed",
        error: "POST only",
        version: ASSEMBLY_VERSION,
      }),
      { status: 405, headers: { "Content-Type": "application/json" } },
    );
  }

  // ========================================
  // AUTH GATE: X-Edge-Secret (internal) OR JWT (external)
  // v1.4.1: Added X-Edge-Secret path for function-to-function calls
  //         (segment-call sends X-Edge-Secret, not JWT)
  // v2.2.1: Uses _shared/auth.ts validateEdgeSecret (constant-time comparison)
  // ========================================
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  const authHeader = req.headers.get("Authorization");

  // Path 1: Internal function-to-function via X-Edge-Secret (constant-time)
  const hasValidEdgeSecret = validateEdgeSecret(req);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({
        ok: false,
        error_code: "bad_request",
        error: "Invalid JSON",
        version: ASSEMBLY_VERSION,
      }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Path 2: External JWT auth (only if no valid edge secret)
  if (!hasValidEdgeSecret) {
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "missing_auth",
          error: "X-Edge-Secret or Authorization: Bearer <token> required",
          version: ASSEMBLY_VERSION,
        }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    // Verify JWT is valid (will fail if token invalid/expired)
    const anonClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authErr } = await anonClient.auth.getUser();
    if (authErr || !user) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "invalid_token",
          error: authErr?.message ?? "Token verification failed",
          version: ASSEMBLY_VERSION,
        }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    // ========================================
    // AUTHORIZATION GATE (PR-10 hardening)
    // Two-layer check: ADMIN_USER_IDS (hard-coded) OR ALLOWED_EMAILS (env)
    // At least one gate must be configured; user must pass at least one
    // ========================================
    const allowedEmails = (Deno.env.get("ALLOWED_EMAILS") || "").split(",").map(
      (e) => e.trim().toLowerCase(),
    ).filter(Boolean);

    const userEmail = (user.email || "").toLowerCase();
    const userId = user.id;

    // Check if user passes either gate
    const isAdmin = ADMIN_USER_IDS.length > 0 && ADMIN_USER_IDS.includes(userId);
    const isAllowedEmail = allowedEmails.length > 0 && allowedEmails.includes(userEmail);

    // At least one gate must be configured
    if (ADMIN_USER_IDS.length === 0 && allowedEmails.length === 0) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "config_error",
          error: "Neither ADMIN_USER_IDS nor ALLOWED_EMAILS configured",
          version: ASSEMBLY_VERSION,
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    // User must pass at least one gate
    if (!isAdmin && !isAllowedEmail) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "forbidden",
          error: "User not authorized",
          version: ASSEMBLY_VERSION,
        }),
        { status: 403, headers: { "Content-Type": "application/json" } },
      );
    }
  }

  const truncations: string[] = [];
  const warnings: string[] = [];
  const sources_used: string[] = [];

  try {
    // ========================================
    // RESOLVE SPAN_ID (span-first)
    // ========================================
    let span_id: string | null = body.span_id || null;
    let interaction_id: string | null = null;

    if (!span_id && body.interaction_id) {
      const span_index = body.span_index ?? 0;
      // POLICY: Active spans only (is_superseded=false)
      const { data: spanRow } = await db
        .from("conversation_spans")
        .select("id, interaction_id")
        .eq("interaction_id", body.interaction_id)
        .eq("span_index", span_index)
        .eq("is_superseded", false)
        .single();

      if (spanRow) {
        span_id = spanRow.id;
        interaction_id = spanRow.interaction_id;
      }
    }

    if (!span_id) {
      return new Response(
        JSON.stringify({
          error: "missing_span_id",
          hint: "Provide span_id directly, or interaction_id + span_index to resolve",
        }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // ========================================
    // FETCH SPAN DATA
    // ========================================
    const { data: span, error: spanErr } = await db
      .from("conversation_spans")
      .select("id, interaction_id, transcript_segment, time_start_sec, time_end_sec, char_start, char_end")
      .eq("id", span_id)
      .single();

    if (spanErr || !span) {
      return new Response(
        JSON.stringify({
          error: "span_not_found",
          span_id,
          db_error: spanErr?.message,
        }),
        {
          status: 404,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    interaction_id = span.interaction_id;
    const transcript_text = span.transcript_segment || "";
    const start_ms = span.time_start_sec != null ? span.time_start_sec * 1000 : null;
    const end_ms = span.time_end_sec != null ? span.time_end_sec * 1000 : null;

    // Fetch words from transcripts_comparison
    let words: any[] | undefined;
    const { data: tc } = await db
      .from("transcripts_comparison")
      .select("words")
      .eq("interaction_id", interaction_id)
      .not("words", "is", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .single();

    if (tc?.words && Array.isArray(tc.words)) {
      words = tc.words;
    }

    // ========================================
    // FETCH CONTACT DATA
    // ========================================
    let contact_id: string | null = null;
    let contact_name: string | null = null;
    let contact_phone: string | null = null;
    let event_at_utc: string | null = null;
    let interaction_project_id: string | null = null;
    let contact_trade: string | null = null;
    let contact_role: string | null = null;
    let contact_is_internal = false; // v2.0.0: for floater modifier
    let fanout_class = "unknown";
    let effective_fanout = 0;
    let floater_flag = false; // Backwards compat: derived from fanout_class

    const interactionContactColumns = DISABLE_INTERACTION_PROJECT_ID_FALLBACKS
      ? "contact_id, contact_name, contact_phone, event_at_utc"
      : "contact_id, contact_name, contact_phone, event_at_utc, project_id";
    const { data: interaction } = await db
      .from("interactions")
      .select(interactionContactColumns)
      .eq("interaction_id", interaction_id)
      .single();

    if (interaction) {
      contact_id = interaction.contact_id;
      contact_name = interaction.contact_name;
      contact_phone = interaction.contact_phone;
      event_at_utc = interaction.event_at_utc;
      if (!DISABLE_INTERACTION_PROJECT_ID_FALLBACKS) {
        interaction_project_id = interaction.project_id || null;
      }
    }

    if (contact_id) {
      const { data: contactRow } = await db
        .from("contacts")
        .select("trade, role, is_internal, floats_between_projects")
        .eq("id", contact_id)
        .single();

      if (contactRow) {
        if (contactRow.trade) contact_trade = String(contactRow.trade);
        if (contactRow.role) contact_role = String(contactRow.role);
        contact_is_internal = !!contactRow.is_internal;
      }
    }

    // v1.5.0: Fetch fanout data from contact_fanout table (DATA-9 D4 spec)
    // Replaces the boolean contacts.floats_between_projects
    if (contact_id) {
      const { data: fanoutRow } = await db
        .from("contact_fanout")
        .select("fanout_class, effective_fanout")
        .eq("contact_id", contact_id)
        .single();

      if (fanoutRow) {
        fanout_class = fanoutRow.fanout_class || "unknown";
        effective_fanout = fanoutRow.effective_fanout || 0;
        // Backwards compat: floater_flag = true if floater or drifter (per DATA-9 D4 spec)
        floater_flag = fanout_class === "floater" || fanout_class === "drifter";
      } else {
        // Fallback: if no fanout row, check legacy boolean
        const { data: contact } = await db
          .from("contacts")
          .select("floats_between_projects")
          .eq("id", contact_id)
          .single();

        if (contact) {
          floater_flag = !!contact.floats_between_projects;
          // Infer fanout_class from legacy flag
          fanout_class = floater_flag ? "floater" : "unknown";
        }
      }
    }

    const recent_projects: RecentProject[] = [];
    if (contact_id) {
      const { data: affRows } = await db
        .from("correspondent_project_affinity")
        .select("project_id, last_interaction_at")
        .eq("contact_id", contact_id)
        .order("last_interaction_at", { ascending: false })
        .limit(5);

      if (affRows?.length) {
        const projectIds = affRows.map((r) => r.project_id).filter(Boolean);
        const { data: prows } = await db
          .from("projects")
          .select("id, name")
          .in("id", projectIds)
          .in("status", VALID_PROJECT_STATUSES)
          .eq("project_kind", VALID_PROJECT_KIND);

        const nameById = new Map((prows || []).map((p) => [p.id, p.name]));

        for (const r of affRows) {
          if (r.project_id) {
            recent_projects.push({
              project_id: r.project_id,
              project_name: nameById.get(r.project_id) || r.project_id,
              last_seen: r.last_interaction_at || null,
            });
          }
        }
      }
    }

    const phone_e164_last4 = contact_phone ? contact_phone.slice(-4) : null;
    let email_context: EmailContextItem[] = [];
    let email_lookup_meta: EmailLookupMeta | null = null;
    let continuity_links: ContinuityLink[] = [];

    // ========================================
    // SOURCE 8: Gmail context lookup (fail-open)
    // - Runs only when a contact is known.
    // - Returns bounded metadata (<=5 messages, no free-text snippets).
    // ========================================
    if (contact_id) {
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const gmailLookupUrl = Deno.env.get("GMAIL_CONTEXT_LOOKUP_URL") ||
        (supabaseUrl ? `${supabaseUrl}/functions/v1/gmail-context-lookup` : null);

      if (gmailLookupUrl) {
        const lookupHeaders: Record<string, string> = {
          "Content-Type": "application/json",
        };

        if (expectedSecret) {
          lookupHeaders["X-Edge-Secret"] = expectedSecret;
        } else if (authHeader?.startsWith("Bearer ")) {
          lookupHeaders["Authorization"] = authHeader;
        }

        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), GMAIL_LOOKUP_TIMEOUT_MS);
        try {
          const gmailResp = await fetch(gmailLookupUrl, {
            method: "POST",
            headers: lookupHeaders,
            body: JSON.stringify({
              contact_id,
              interaction_id,
              span_id,
              lookback_days: GMAIL_LOOKUP_DEFAULT_LOOKBACK_DAYS,
              max_results: GMAIL_LOOKUP_DEFAULT_MAX_RESULTS,
              source: "context-assembly",
            }),
            signal: controller.signal,
          });

          if (!gmailResp.ok) {
            warnings.push(`gmail_lookup_http_${gmailResp.status}`);
          } else {
            const gmailPayload = await gmailResp.json().catch(() => null);
            if (gmailPayload?.ok) {
              email_context = Array.isArray(gmailPayload.email_context)
                ? gmailPayload.email_context as EmailContextItem[]
                : [];
              email_lookup_meta = gmailPayload.email_lookup_meta &&
                  typeof gmailPayload.email_lookup_meta === "object"
                ? gmailPayload.email_lookup_meta as EmailLookupMeta
                : null;
              sources_used.push("gmail_context_lookup");
              if (email_lookup_meta?.warnings?.length) {
                warnings.push(...email_lookup_meta.warnings.map((w) => `gmail:${w}`));
              }
              if (email_lookup_meta?.truncation?.length) {
                truncations.push(...email_lookup_meta.truncation.map((t) => `gmail:${t}`));
              }
            } else {
              warnings.push("gmail_lookup_invalid_payload");
            }
          }
        } catch (error: any) {
          if (error?.name === "AbortError") {
            warnings.push("gmail_lookup_timeout");
          } else {
            warnings.push(`gmail_lookup_exception:${String(error?.message || error).slice(0, 100)}`);
          }
        } finally {
          clearTimeout(timeoutId);
        }
      } else {
        warnings.push("gmail_lookup_url_missing");
      }
    }

    const gmailMentionedProjectIds: string[] = Array.from(
      new Set(
        email_context
          .flatMap((item) => Array.isArray(item.mentioned_project_ids) ? item.mentioned_project_ids : [])
          .filter((id) => !!id),
      ),
    );

    let materialStructuralSignalScore = 0;
    let homeownerOverrideProjectId: string | null = null;
    let homeownerOverrideApplied = false;
    let homeownerOverrideConflictProjectId: string | null = null;
    let homeownerOverrideConflictTerm: string | null = null;
    let homeownerOverrideSkippedReason: string | null = null;
    let clientOverrideProjectId: string | null = null;
    let clientOverrideApplied = false;
    let clientOverrideConflictProjectId: string | null = null;
    let clientOverrideConflictTerm: string | null = null;
    let clientOverrideSkippedReason: string | null = null;

    // ========================================
    // 7-SOURCE CANDIDATE COLLECTION
    // (plus Source 8 Gmail context lookup above)
    // ========================================
    const candidatesById = new Map<string, {
      project_id: string;
      assigned: boolean;
      affinity_weight: number;
      sources: string[];
      alias_matches: AliasMatch[];
      source_scores: Record<string, number>;
      source_strength: number;
      claim_content_match_terms?: string[];
      cross_contact_claim_match_terms?: string[];
      material_budget_tier_terms?: string[];
      geo_distance_km?: number;
      geo_signal?: GeoSignal;
    }>();
    const mysteryWhiteMaterialMentioned = transcript_text
      ? /\bmystery\s+white\b/i.test(stripSpeakerLabels(transcript_text))
      : false;
    const commonWordAliasWarnings = new Set<string>();

    // Load blocklist once, then enforce globally after all candidate sources are aggregated.
    const { data: blockedRows } = await db
      .from("project_attribution_blocklist")
      .select("project_id")
      .eq("active", true)
      .eq("block_mode", "hard_block");
    const blockedProjectIds = new Set(
      (blockedRows || [])
        .map((r: { project_id: string | null }) => r.project_id)
        .filter((v): v is string => !!v),
    );
    if (blockedProjectIds.size > 0) {
      console.log(`[context-assembly] Blocklist active: ${blockedProjectIds.size} projects`);
    }

    const addCandidate = (
      pid: string,
      source: string,
      weight = 0,
      geo_distance_km?: number,
      geo_signal?: GeoSignal,
      sourceScore = 0,
    ) => {
      if (!pid) return;
      const cur = candidatesById.get(pid) || {
        project_id: pid,
        assigned: false,
        affinity_weight: 0,
        sources: [],
        alias_matches: [],
        source_scores: {},
        source_strength: 0,
      };
      if (!cur.sources.includes(source)) cur.sources.push(source);
      if (weight > 0) cur.affinity_weight = Math.max(cur.affinity_weight, weight);
      if (sourceScore !== 0) {
        cur.source_scores[source] = (cur.source_scores[source] || 0) + sourceScore;
        cur.source_strength += sourceScore;
      }
      if (geo_distance_km !== undefined) {
        cur.geo_distance_km = cur.geo_distance_km !== undefined
          ? Math.min(cur.geo_distance_km, geo_distance_km)
          : geo_distance_km;
      }
      if (geo_signal) {
        if (!cur.geo_signal) {
          cur.geo_signal = geo_signal;
        } else {
          const mergedCounts: Record<PlaceRole, number> = {
            proximity: (cur.geo_signal.role_counts.proximity || 0) + (geo_signal.role_counts.proximity || 0),
            origin: (cur.geo_signal.role_counts.origin || 0) + (geo_signal.role_counts.origin || 0),
            destination: (cur.geo_signal.role_counts.destination || 0) +
              (geo_signal.role_counts.destination || 0),
          };
          cur.geo_signal = {
            score: Math.max(cur.geo_signal.score, geo_signal.score),
            dominant_role: dominantRoleFromCounts(mergedCounts),
            role_counts: mergedCounts,
            place_count: Math.max(cur.geo_signal.place_count, geo_signal.place_count),
          };
        }
      }
      candidatesById.set(pid, cur);
    };

    // SOURCE 1: project_contacts (direct assignment)
    if (contact_id) {
      const { data: pcRows } = await db
        .from("project_contacts")
        .select("*")
        .eq("contact_id", contact_id);

      if (pcRows?.length) {
        const homeownerProjectIds = new Set<string>();
        const source1ProjectIds = new Set<string>();
        sources_used.push("project_contacts");
        for (const r of pcRows as Array<Record<string, unknown>>) {
          const projectId = typeof r.project_id === "string" ? r.project_id : null;
          if (projectId) {
            source1ProjectIds.add(projectId);
            addCandidate(projectId, "project_contacts", 0, undefined, undefined, SOURCE_SCORE_PROJECT_CONTACT);
            const cur = candidatesById.get(projectId);
            if (cur) {
              cur.assigned = true;
              const rowTrade = normalizeTradeLabel(typeof r.trade === "string" ? r.trade : null);
              const contactTrade = normalizeTradeLabel(contact_trade);
              if (rowTrade && contactTrade && rowTrade === contactTrade) {
                addCandidate(
                  projectId,
                  "other_party_trade_match",
                  0,
                  undefined,
                  undefined,
                  SOURCE_SCORE_OTHER_PARTY_TRADE_MATCH,
                );
              }
            }

            const pcTrade = r.trade;
            const homeownerLabelCandidates = [
              r.contact_role,
              r.role,
              r.trade,
            ];
            if (homeownerLabelCandidates.some((value) => isHomeownerRoleLabel(value, pcTrade))) {
              homeownerProjectIds.add(projectId);
            }
          }
        }

        if (homeownerProjectIds.size === 1) {
          homeownerOverrideProjectId = Array.from(homeownerProjectIds)[0];
        } else if (homeownerProjectIds.size > 1) {
          homeownerOverrideSkippedReason = "homeowner_link_not_unique";
          warnings.push("homeowner_override_not_unique");
        } else if (
          isHomeownerRoleLabel(contact_role, contact_trade) ||
          isHomeownerRoleLabel(contact_trade)
        ) {
          if (source1ProjectIds.size === 1) {
            homeownerOverrideProjectId = Array.from(source1ProjectIds)[0];
            sources_used.push("homeowner_contact_role_fallback");
          } else if (source1ProjectIds.size > 1) {
            homeownerOverrideSkippedReason = "homeowner_contact_multi_project";
            warnings.push("homeowner_override_contact_multi_project");
          }
        }
      }
    }

    // CLIENT OVERRIDE: Query project_clients table for this contact
    if (contact_id) {
      const { data: clientRows } = await db
        .from("project_clients")
        .select("project_id, client_role")
        .eq("contact_id", contact_id);

      if (clientRows?.length) {
        const clientProjectIds = new Set<string>();
        for (const r of clientRows as Array<Record<string, unknown>>) {
          const projectId = typeof r.project_id === "string" ? r.project_id : null;
          if (projectId) {
            clientProjectIds.add(projectId);
            // Also add as a candidate source if not already present
            addCandidate(
              projectId,
              "project_clients",
              0,
              undefined,
              undefined,
              SOURCE_SCORE_PROJECT_CONTACT,
            );
            const cur = candidatesById.get(projectId);
            if (cur) cur.assigned = true;
          }
        }

        if (clientProjectIds.size === 1) {
          // Don't override if homeowner already set (homeowner takes precedence)
          if (!homeownerOverrideProjectId) {
            clientOverrideProjectId = Array.from(clientProjectIds)[0];
          } else {
            clientOverrideSkippedReason = "homeowner_override_active";
          }
        } else if (clientProjectIds.size > 1) {
          clientOverrideSkippedReason = "client_link_not_unique";
          warnings.push("client_override_not_unique");
        }

        if (!sources_used.includes("project_clients")) {
          sources_used.push("project_clients");
        }
      }
    }

    // SOURCE 2: correspondent_project_affinity
    // v2.0.0 Floater modifier: halve affinity weights for internal floaters
    const isInternalFloater = floater_flag && contact_is_internal;
    if (contact_id) {
      const { data: affRows } = await db
        .from("correspondent_project_affinity")
        .select("project_id, weight")
        .eq("contact_id", contact_id);

      if (affRows?.length) {
        sources_used.push("correspondent_project_affinity");
        for (const r of affRows) {
          if (r.project_id) {
            let affinityWeight = Number(r.weight || 0);
            // v2.0.0 Floater modifier: discount affinity for internal floaters
            if (isInternalFloater) {
              affinityWeight *= FLOATER_AFFINITY_DISCOUNT;
            }
            addCandidate(
              r.project_id,
              "correspondent_project_affinity",
              affinityWeight,
              undefined,
              undefined,
              affinityWeight,
            );
          }
        }
      }
    }

    // SOURCE 3: existing_project from interactions
    if (!DISABLE_INTERACTION_PROJECT_ID_FALLBACKS) {
      const { data: irows } = await db
        .from("interactions")
        .select("project_id")
        .eq("interaction_id", interaction_id)
        .limit(1);

      if (irows?.[0]?.project_id) {
        addCandidate(
          irows[0].project_id,
          "interactions_existing_project",
          0,
          undefined,
          undefined,
          SOURCE_SCORE_PROJECT_CONTACT / 2,
        );
        sources_used.push("interactions_existing_project");
      }
    }

    // SOURCE 1.5: gmail_content_match (seed by email-mentioned projects)
    if (gmailMentionedProjectIds.length > 0) {
      sources_used.push("gmail_content_match");
      for (const pid of gmailMentionedProjectIds) {
        addCandidate(
          pid,
          "gmail_content_match",
          0,
          undefined,
          undefined,
          SOURCE_SCORE_GMAIL_CONTENT_MATCH,
        );
      }
    }

    const matchPositions: number[] = [];
    let callbackSpans: string[] = [];
    const projectMentionSpans: string[] = [];
    const place_mentions: PlaceMention[] = [];
    let transcriptTokens: string[] = [];
    const transcriptClean = transcript_text ? stripSpeakerLabels(transcript_text) : "";

    // SOURCE 4-7: Transcript-based sources
    if (transcript_text) {
      const transcriptLower = transcriptClean.toLowerCase();
      transcriptTokens = tokenizeTextForOverlap(transcriptClean);
      callbackSpans = findCallbackPhraseSpans(transcriptClean, transcriptLower);

      // Fetch all projects + aliases for matching
      // PR-11: Filter by status and project_kind to exclude inactive/internal projects
      const { data: allProjects } = await db.from("projects").select("id, name, aliases, city, address")
        .in("status", VALID_PROJECT_STATUSES)
        .eq("project_kind", VALID_PROJECT_KIND);

      // Pre-filter transcript-scan project corpus by blocklist; final global filter is applied later.
      const projects = (allProjects || []).filter(
        (p: { id: string }) => !blockedProjectIds.has(p.id),
      );

      let aliasRows: Array<{ project_id: string; alias: string }> | null = null;
      try {
        const { data, error } = await db.from("v_project_alias_lookup").select("project_id, alias");
        if (!error && data) {
          aliasRows = data;
        } else if (error) {
          warnings.push("v_project_alias_lookup_missing");
        }
      } catch {
        warnings.push("v_project_alias_lookup_error");
      }

      const aliasByProject = new Map<string, string[]>();
      for (const r of (aliasRows || [])) {
        if (!r.project_id || !r.alias) continue;
        if (blockedProjectIds.has(r.project_id)) continue; // Skip blocked project aliases
        if (!aliasByProject.has(r.project_id)) aliasByProject.set(r.project_id, []);
        aliasByProject.get(r.project_id)!.push(r.alias);
      }

      try {
        const { data: materialRows } = await db
          .from("material_signal_config")
          .select("term, aliases, boost")
          .eq("active", true);
        if (materialRows?.length) {
          for (const row of materialRows) {
            const aliases = Array.isArray(row.aliases) ? row.aliases : [];
            const terms = [row.term, ...aliases].map((v) => String(v || "").trim()).filter(Boolean);
            const matchFound = terms.some((term) => {
              const termLower = String(term).toLowerCase();
              return findTermInText(transcriptLower, termLower) >= 0;
            });

            if (matchFound) {
              const rowBoost = Number(row.boost || 0);
              materialStructuralSignalScore += SOURCE_SCORE_MATERIAL_STRUCTURAL_BASE + Math.max(0, rowBoost);
            }
          }
          materialStructuralSignalScore = clamp(
            materialStructuralSignalScore,
            0,
            SOURCE_SCORE_MATERIAL_STRUCTURAL_MAX,
          );
        }
      } catch {
        warnings.push("material_signal_config_unavailable");
      }

      // SOURCE 4: Name/alias/location matches in transcript
      if (projects) {
        sources_used.push("transcript_scan");
        for (const p of projects) {
          if (!p.id || !p.name) continue;

          const terms: string[] = [p.name];
          const fromAliasTable = aliasByProject.get(p.id) || [];
          terms.push(...fromAliasTable);
          if (Array.isArray(p.aliases)) terms.push(...p.aliases);
          if (p.city) terms.push(p.city);
          if (p.address) terms.push(p.address);

          const normalizedTerms = normalizeAliasTerms(terms).slice(0, MAX_ALIAS_TERMS_PER_PROJECT);

          for (const term of normalizedTerms) {
            const termLower = term.toLowerCase();
            const idx = findTermInText(transcriptLower, termLower);
            if (idx >= 0) {
              matchPositions.push(idx);

              const matchType = fromAliasTable.some((a) => a.toLowerCase() === termLower)
                ? "alias"
                : (p.name.toLowerCase() === termLower ? "exact_project_name" : "city_or_location");
              const isCommonWordLexeme = COMMON_WORD_ALIAS_TERMS.has(termLower) &&
                (matchType === "alias" || matchType === "city_or_location");
              if (isCommonWordLexeme && mysteryWhiteMaterialMentioned) {
                if (!commonWordAliasWarnings.has(termLower)) {
                  warnings.push(`common_word_alias_ignored:${termLower}`);
                  commonWordAliasWarnings.add(termLower);
                }
                continue;
              }

              const cur: {
                project_id: string;
                assigned: boolean;
                affinity_weight: number;
                sources: string[];
                alias_matches: AliasMatch[];
                source_scores: Record<string, number>;
                source_strength: number;
              } = candidatesById.get(p.id) || {
                project_id: p.id,
                assigned: false,
                affinity_weight: 0,
                sources: [],
                alias_matches: [],
                source_scores: {},
                source_strength: 0,
              };
              if (!cur.sources.includes("transcript_scan")) cur.sources.push("transcript_scan");
              const snippet = snippetAround(transcriptClean, idx, term.length);
              if (projectMentionSpans.length < 5) {
                projectMentionSpans.push(snippet.slice(0, 80));
              }
              cur.alias_matches.push({
                term,
                match_type: matchType,
                snippet,
              });
              candidatesById.set(p.id, cur);
            }
          }
        }
      }

      // SOURCE 5: RPC scan_transcript_for_projects
      try {
        const { data: scanData, error: scanErr } = await db.rpc("scan_transcript_for_projects", {
          transcript_text: transcript_text,
          similarity_threshold: 0.4,
        });

        if (!scanErr && scanData?.length) {
          sources_used.push("rpc_scan_transcript_for_projects");
          for (const r of scanData) {
            const pid = r.project_id || r.projectId;
            if (pid) {
              const score = Number(r.score || r.similarity || 0) || 0;
              addCandidate(pid, "rpc_scan_transcript_for_projects", score);

              const cur = candidatesById.get(pid);
              if (cur && r.matched_term) {
                cur.alias_matches.push({ term: r.matched_term, match_type: "db_scan" });
              }
            }
          }
        }
      } catch { /* RPC may not exist */ }

      // SOURCE 6: RPC expand_candidates_from_mentions
      try {
        const { data: mentionData, error: mentionErr } = await db.rpc("expand_candidates_from_mentions", {
          transcript_text: transcript_text,
        });

        if (!mentionErr && mentionData?.length) {
          sources_used.push("rpc_expand_candidates_from_mentions");
          for (const r of mentionData) {
            const pid = r.project_id || r.projectId;
            if (pid) {
              const affinity = Number(r.contact_affinity || r.affinity || 0.9) || 0.9;
              addCandidate(pid, "mentioned_contact_affinity", affinity);

              const cur = candidatesById.get(pid);
              if (cur && r.mentioned_contact) {
                cur.alias_matches.push({
                  term: r.mentioned_contact,
                  match_type: "mentioned_contact",
                });
              }
            }
          }
        }
      } catch { /* RPC may not exist */ }

      // POST-PROCESS: first-name unique anchor (Lever 2)
      // When a weak single-word first-name alias match uniquely identifies
      // exactly one candidate in the pool, promote it to first_name_unique.
      // Safety: only for candidates already present from another source.
      {
        // Build map: lowercase single-word term -> set of project_ids that matched it
        const termToProjects = new Map<string, Set<string>>();
        for (const [pid, meta] of candidatesById) {
          for (const m of meta.alias_matches) {
            const t = m.term.trim();
            if (!t.includes(" ") && t.length >= 3 && t.length < 6) {
              const key = t.toLowerCase();
              if (!termToProjects.has(key)) termToProjects.set(key, new Set());
              termToProjects.get(key)!.add(pid);
            }
          }
        }
        // Promote unique first-name matches on multi-source candidates
        for (const [, meta] of candidatesById) {
          const hasOtherSource = meta.sources.some((s) => s !== "transcript_scan");
          if (!hasOtherSource) continue;
          for (const m of meta.alias_matches) {
            const t = m.term.trim();
            if (t.includes(" ") || t.length < 3 || t.length >= 6) continue;
            const key = t.toLowerCase();
            const matchingPids = termToProjects.get(key);
            if (matchingPids && matchingPids.size === 1) {
              m.match_type = "first_name_unique";
            }
          }
        }
      }

      // ========================================
      // SOURCE 7: GEO + ENROUTE DETECTION
      // POLICY (STRAT-1 BLOCK):
      // - Role is VERB-DRIVEN only
      // - Single place without verb = "proximity"
      // - NEVER infer direction from single place
      // ========================================
      try {
        const { data: places, error: placesErr } = await db
          .from("geo_places")
          .select("id, name, state, lat, lon");

        if (!placesErr && places?.length) {
          const mentionedPlaces: Array<{
            id: string;
            name: string;
            lat: number;
            lon: number;
            char_offset: number;
            role: PlaceRole;
            trigger_verb: string | null;
            snippet: string;
          }> = [];

          for (const place of places) {
            if (!place.name || place.lat == null || place.lon == null) continue;

            const placeNameLower = place.name.toLowerCase();
            if (placeNameLower.length < 4) continue;

            const idx = findTermInText(transcriptLower, placeNameLower);
            if (idx >= 0) {
              // VERB-DRIVEN ROLE DETECTION
              const { role, trigger_verb } = detectPlaceRole(transcriptLower, idx, placeNameLower);

              const mention: PlaceMention = {
                place_name: place.name,
                geo_place_id: place.id,
                lat: place.lat,
                lon: place.lon,
                role,
                trigger_verb,
                char_offset: idx,
                snippet: snippetAround(transcriptClean, idx, place.name.length),
              };

              place_mentions.push(mention);

              mentionedPlaces.push({
                id: place.id,
                name: place.name,
                lat: place.lat,
                lon: place.lon,
                char_offset: idx,
                role,
                trigger_verb,
                snippet: mention.snippet,
              });
            }
          }

          // Insert place mentions into span_place_mentions (upsert)
          if (mentionedPlaces.length > 0) {
            sources_used.push("geo_proximity");

            // Map to actual DB schema: (span_id, place_id, mention_text, role, verb_hint, confidence)
            // PK is (span_id, place_id, mention_text)
            const insertRows = mentionedPlaces.map((p) => ({
              span_id: span_id,
              place_id: p.id,
              mention_text: p.name,
              role: p.role,
              verb_hint: p.trigger_verb,
              confidence: p.role === "proximity" ? 0.5 : 0.8,
            }));

            // Upsert using PK columns (PR-9 hotfix)
            // PK: span_place_mentions_pkey (span_id, place_id, mention_text)
            const { error: upsertErr } = await db.from("span_place_mentions").upsert(insertRows, {
              onConflict: "span_id,place_id,mention_text",
            });
            if (upsertErr) {
              // FAIL CLOSED: upsert failure is fatal (schema/PK mismatch)
              return new Response(
                JSON.stringify({
                  ok: false,
                  error_code: "span_place_mentions_upsert_failed",
                  error: upsertErr.message,
                  version: ASSEMBLY_VERSION,
                  ms: Date.now() - t0,
                }),
                { status: 500, headers: { "Content-Type": "application/json" } },
              );
            }

            // Log enroute detections
            const enrouteCount = mentionedPlaces.filter((p) => p.role !== "proximity").length;
            if (enrouteCount > 0) {
              warnings.push(`enroute_detected:${enrouteCount}`);
            }

            // Find nearby projects (geo proximity candidates)
            // PR-11: Join projects table to filter by status and project_kind
            const { data: projectGeos, error: geoErr } = await db
              .from("project_geo")
              .select("project_id, lat, lon, projects!inner(status, project_kind)")
              .in("projects.status", VALID_PROJECT_STATUSES)
              .eq("projects.project_kind", VALID_PROJECT_KIND);

            if (!geoErr && projectGeos?.length) {
              const nearbyProjects = new Map<
                string,
                {
                  min_distance_km: number;
                  role_counts: Record<PlaceRole, number>;
                  place_names: Set<string>;
                }
              >();

              for (const place of mentionedPlaces) {
                for (const pg of projectGeos) {
                  if (!pg.project_id || pg.lat == null || pg.lon == null) continue;

                  const distance = haversineDistanceKm(
                    place.lat,
                    place.lon,
                    pg.lat,
                    pg.lon,
                  );

                  if (distance <= GEO_MAX_DISTANCE_KM) {
                    const existing = nearbyProjects.get(pg.project_id) || {
                      min_distance_km: Number.POSITIVE_INFINITY,
                      role_counts: emptyRoleCounts(),
                      place_names: new Set<string>(),
                    };
                    existing.min_distance_km = Math.min(existing.min_distance_km, distance);
                    existing.role_counts[place.role] = (existing.role_counts[place.role] || 0) + 1;
                    existing.place_names.add(place.name);
                    nearbyProjects.set(pg.project_id, existing);
                  }
                }
              }

              const sortedNearby = Array.from(nearbyProjects.entries())
                .sort((a, b) => a[1].min_distance_km - b[1].min_distance_km)
                .slice(0, GEO_MAX_CANDIDATES);

              for (const [pid, signal] of sortedNearby) {
                const placeCount = signal.place_names.size;
                const weakGeoScore = computeGeoWeakScore(
                  signal.min_distance_km,
                  signal.role_counts,
                  placeCount,
                );
                addCandidate(
                  pid,
                  "geo_proximity",
                  0,
                  Math.round(signal.min_distance_km * 10) / 10,
                  {
                    score: Math.round(weakGeoScore * 100) / 100,
                    dominant_role: dominantRoleFromCounts(signal.role_counts),
                    role_counts: signal.role_counts,
                    place_count: placeCount,
                  },
                );
              }

              if (sortedNearby.length > 0) {
                warnings.push(`geo_candidates_added:${sortedNearby.length}`);
                warnings.push("geo_ai_signal_enriched");
              }
            }
          }
        }
      } catch (_geoErr) {
        warnings.push("geo_lookup_skipped");
      }
    }

    if (materialStructuralSignalScore > 0 && candidatesById.size > 0) {
      sources_used.push("material_structural_mentions");
      for (const [pid] of candidatesById) {
        addCandidate(
          pid,
          "material_structural_mentions",
          0,
          undefined,
          undefined,
          materialStructuralSignalScore,
        );
      }
    }

    if (floater_flag && candidatesById.size > 0) {
      sources_used.push("floater_anti_signal");
      for (const [pid] of candidatesById) {
        addCandidate(
          pid,
          "floater_anti_signal",
          0,
          undefined,
          undefined,
          SOURCE_SCORE_FLOATER_ANTI_SIGNAL,
        );
      }
    }

    // SOURCE 8: Journal claim content overlap (transcript against active claims)
    if (transcript_text && transcriptTokens.length > 0) {
      const transcriptHighSignalTokens = transcriptTokens.filter((t) => !isLowSignalLexeme(t));
      if (transcriptHighSignalTokens.length === 0) {
        warnings.push("claim_content_match_low_signal_terms");
      }
      const claimProjectIds = new Set<string>();
      for (const pid of candidatesById.keys()) {
        claimProjectIds.add(pid);
      }
      if (!DISABLE_INTERACTION_PROJECT_ID_FALLBACKS && !claimProjectIds.size && interaction_project_id) {
        claimProjectIds.add(interaction_project_id);
      }

      if (claimProjectIds.size > 0 && transcriptHighSignalTokens.length > 0) {
        try {
          const { data: claimRows, error: claimErr } = await db
            .from("journal_claims")
            .select("project_id, call_id, claim_text")
            .in("project_id", Array.from(claimProjectIds))
            .eq("active", true)
            .eq("claim_confirmation_state", "confirmed")
            .order("created_at", { ascending: false })
            .limit(Math.max(8, claimProjectIds.size * 8));

          if (!claimErr && claimRows?.length) {
            const callIds = Array.from(
              new Set((claimRows || []).map((c) => c.call_id).filter(Boolean)),
            );
            const claimSourceByCall = new Map<string, { contact_id: string | null; contact_phone: string | null }>();

            if (callIds.length > 0) {
              const { data: sourceCallRows } = await db
                .from("interactions")
                .select("interaction_id, contact_id, contact_phone")
                .in("interaction_id", callIds);

              for (const row of (sourceCallRows || [])) {
                claimSourceByCall.set(row.interaction_id, {
                  contact_id: row.contact_id,
                  contact_phone: row.contact_phone,
                });
              }
            }

            const bestClaimMatchByProject = new Map<
              string,
              { score: number; snippets: string[]; terms: string[] }
            >();

            for (const row of claimRows) {
              if (!row.project_id || !row.claim_text) continue;
              const source = claimSourceByCall.get(row.call_id);

              const isMatchedScope = contact_id
                ? source
                  ? matchesJournalSourceContact(contact_id, contact_phone, source.contact_id, source.contact_phone)
                  : false
                : !DISABLE_INTERACTION_PROJECT_ID_FALLBACKS && interaction_project_id
                ? row.project_id === interaction_project_id
                : false;

              if (!isMatchedScope) continue;

              const claimHighSignalTokens = tokenizeTextForOverlap(row.claim_text)
                .map((t) => t.toLowerCase())
                .filter((t) => !isLowSignalLexeme(t));
              const overlapTerms = overlappingTokenTerms(transcriptHighSignalTokens, claimHighSignalTokens);
              const overlapDenominator = new Set(claimHighSignalTokens).size;
              const overlap = overlapDenominator > 0 ? overlapTerms.length / overlapDenominator : 0;
              if (overlap <= 0) continue;

              const existing = bestClaimMatchByProject.get(row.project_id) || { score: 0, snippets: [], terms: [] };
              existing.score = Math.max(
                existing.score,
                clamp(overlap * 2.2, 0, SOURCE_SCORE_CLAIM_CONTENT_MATCH_PER_SIGNAL),
              );
              if (existing.snippets.length < 2) {
                const trimmed = String(row.claim_text).slice(0, 120);
                existing.snippets.push(trimmed);
              }
              for (const term of overlapTerms) {
                if (!existing.terms.includes(term) && existing.terms.length < CLAIM_CONTENT_EVIDENCE_TERM_LIMIT) {
                  existing.terms.push(term);
                }
              }
              bestClaimMatchByProject.set(row.project_id, existing);
            }

            if (bestClaimMatchByProject.size > 0) {
              sources_used.push("claim_content_match");
              for (const [pid, match] of bestClaimMatchByProject) {
                addCandidate(
                  pid,
                  "claim_content_match",
                  0,
                  undefined,
                  undefined,
                  clamp(match.score, 0, SOURCE_SCORE_CLAIM_CONTENT_MATCH_PER_SIGNAL),
                );

                const cur = candidatesById.get(pid);
                if (cur) {
                  for (const snippet of match.snippets) {
                    cur.alias_matches.push({
                      term: "claim_content_match",
                      match_type: "claim_content_match",
                      snippet,
                    });
                  }
                  if (match.terms.length > 0) {
                    cur.claim_content_match_terms = match.terms.slice(0, CLAIM_CONTENT_EVIDENCE_TERM_LIMIT);
                  }
                }
              }
            }
          }
        } catch {
          warnings.push("claim_content_match_skipped");
        }
      }
    }

    // ========================================
    // SOURCE 9: OTHER_PARTY_TRADE_MATCH (v2.0.0)
    // Parse non-contact speaker names from transcript, fuzzy match to contacts,
    // get their trade, find projects with that trade via project_contacts.
    // ========================================
    if (transcript_text) {
      try {
        const speakerLabelPattern = /(?:^|\n)\s*([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s*:/g;
        const detectedNames = new Set<string>();
        let speakerMatch: RegExpExecArray | null;
        while ((speakerMatch = speakerLabelPattern.exec(transcript_text)) !== null) {
          const name = speakerMatch[1].trim();
          if (name && name.length >= 3 && !/^(Agent|Customer|Speaker|Unknown|System)$/i.test(name)) {
            detectedNames.add(name);
          }
        }

        if (detectedNames.size > 0) {
          const { data: allContacts } = await db
            .from("contacts")
            .select("id, name, trade")
            .not("trade", "is", null);

          if (allContacts?.length) {
            const matchedTrades = new Set<string>();
            for (const detectedName of detectedNames) {
              const nameLower = detectedName.toLowerCase();
              for (const c of allContacts) {
                if (!c.name || !c.trade || c.id === contact_id) continue;
                const contactNameLower = c.name.toLowerCase();
                if (contactNameLower.includes(nameLower) || nameLower.includes(contactNameLower)) {
                  matchedTrades.add(normalizeTradeLabel(c.trade));
                }
              }
            }

            if (matchedTrades.size > 0) {
              const { data: tradeProjectRows } = await db
                .from("project_contacts")
                .select("project_id, trade")
                .eq("is_active", true);

              if (tradeProjectRows?.length) {
                const tradeMatchProjects = new Set<string>();
                for (const r of tradeProjectRows) {
                  if (r.project_id && r.trade && matchedTrades.has(normalizeTradeLabel(r.trade))) {
                    tradeMatchProjects.add(r.project_id);
                  }
                }
                if (tradeMatchProjects.size > 0) {
                  sources_used.push("other_party_trade_match_v2");
                  for (const pid of tradeMatchProjects) {
                    addCandidate(
                      pid,
                      "other_party_trade_match",
                      0,
                      undefined,
                      undefined,
                      SOURCE_SCORE_OTHER_PARTY_TRADE_MATCH,
                    );
                  }
                }
              }
            }
          }
        }
      } catch {
        warnings.push("other_party_trade_match_skipped");
      }
    }

    // ========================================
    // SOURCE 10: CLAIM_CONTENT_MATCH — Cross-contact (v2.0.0)
    // Unlike the contact-scoped claim match above, this queries ALL active claims
    // across all contacts. Key for resolving floater calls.
    // ========================================
    if (transcriptClean && transcriptTokens.length > 0) {
      try {
        const highSignalTerms = extractHighSignalCrossContactTerms(transcriptClean);
        const evidenceTerms = highSignalTerms.slice(0, CROSS_CONTACT_EVIDENCE_TERM_LIMIT);
        const searchTerms = buildCrossContactSearchTerms(highSignalTerms);

        if (searchTerms.length >= CROSS_CONTACT_MIN_SEARCH_TERMS) {
          const likePatterns = searchTerms
            .map((term) => `%${term}%`)
            .filter((pattern) => pattern.length > 3);

          const { data: crossClaimRows, error: crossClaimErr } = await db
            .from("journal_claims")
            .select("claim_project_id")
            .eq("active", true)
            .eq("claim_confirmation_state", "confirmed")
            .not("claim_project_id", "is", null)
            .or(likePatterns.map((p) => `claim_text.ilike.${p}`).join(","))
            .limit(100);

          if (!crossClaimErr && crossClaimRows?.length) {
            const hitsByProject = new Map<string, number>();
            for (const row of crossClaimRows) {
              if (!row.claim_project_id) continue;
              hitsByProject.set(
                row.claim_project_id,
                (hitsByProject.get(row.claim_project_id) || 0) + 1,
              );
            }

            const sortedProjectsAll = Array.from(hitsByProject.entries())
              .sort((a, b) => b[1] - a[1]);

            if (sortedProjectsAll.length > 0) {
              const projectIds = sortedProjectsAll.map(([pid]) => pid);
              const { data: activeProjects } = await db
                .from("projects")
                .select("id")
                .in("id", projectIds)
                .in("status", VALID_PROJECT_STATUSES)
                .eq("project_kind", VALID_PROJECT_KIND);

              const activeIds = new Set((activeProjects || []).map((p) => p.id));
              const sortedProjects = sortedProjectsAll
                .filter(([pid]) => activeIds.has(pid))
                .slice(0, 5);

              if (sortedProjects.length > 0) {
                sources_used.push("cross_contact_claim_match");
                for (const [pid, hits] of sortedProjects) {
                  const score = SOURCE_SCORE_CROSS_CONTACT_CLAIM_MATCH * Math.min(hits / 5, 1.0);
                  addCandidate(pid, "cross_contact_claim_match", 0, undefined, undefined, score);
                  const cur = candidatesById.get(pid);
                  if (cur && evidenceTerms.length > 0) {
                    cur.cross_contact_claim_match_terms = evidenceTerms;
                  }
                }
              }
            }
          }
        } else {
          warnings.push("cross_contact_claim_match_low_signal_terms");
        }
      } catch {
        warnings.push("cross_contact_claim_match_skipped");
      }
    }

    // ========================================
    // SOURCE 11: MATERIAL_BUDGET_TIER_MATCH (v2.0.0)
    // Match material keywords in transcript to budget tier to projects by contract_value
    // ========================================
    if (transcript_text) {
      try {
        const transcriptLower = transcript_text.toLowerCase();

        const { data: materialRows } = await db
          .from("material_budget_tiers")
          .select("tier, keywords");

        if (materialRows?.length) {
          const matchedTiers = new Set<string>();
          const matchedTermsByTier = new Map<string, string[]>();
          let lowSignalKeywordFilteredCount = 0;
          for (const row of materialRows) {
            if (!row.keywords || !row.tier) continue;
            const keywords: string[] = Array.isArray(row.keywords) ? row.keywords : [];
            for (const kw of keywords) {
              const normalizedKeyword = sanitizeCrossContactTerm(String(kw || ""));
              if (!normalizedKeyword) continue;
              if (isLowSignalMaterialBudgetKeyword(normalizedKeyword)) {
                lowSignalKeywordFilteredCount += 1;
                continue;
              }
              if (findTermInText(transcriptLower, normalizedKeyword) >= 0) {
                matchedTiers.add(row.tier);
                const terms = matchedTermsByTier.get(row.tier) || [];
                if (!terms.includes(normalizedKeyword) && terms.length < MATERIAL_BUDGET_EVIDENCE_TERM_LIMIT) {
                  terms.push(normalizedKeyword);
                }
                matchedTermsByTier.set(row.tier, terms);
                break;
              }
            }
          }

          if (lowSignalKeywordFilteredCount > 0) {
            warnings.push(`material_budget_tier_low_signal_filtered:${lowSignalKeywordFilteredCount}`);
          }

          if (matchedTiers.size > 0) {
            const { data: activeProjects } = await db
              .from("projects")
              .select("id, contract_value")
              .in("status", VALID_PROJECT_STATUSES)
              .eq("project_kind", VALID_PROJECT_KIND)
              .not("contract_value", "is", null);

            if (activeProjects?.length) {
              const tierMatches = new Set<string>();
              for (const tier of matchedTiers) {
                const midpoint = TIER_MIDPOINTS[tier];
                if (!midpoint) continue;

                const sorted = activeProjects
                  .filter((p) => p.contract_value != null)
                  .map((p) => ({ id: p.id, distance: Math.abs(Number(p.contract_value) - midpoint) }))
                  .sort((a, b) => a.distance - b.distance)
                  .slice(0, 3);

                for (const match of sorted) {
                  tierMatches.add(match.id);
                }
              }

              if (tierMatches.size > 0) {
                sources_used.push("material_budget_tier");
                const evidenceTerms = Array.from(
                  new Set(
                    Array.from(matchedTiers).flatMap((tier) => matchedTermsByTier.get(tier) || []),
                  ),
                ).slice(0, MATERIAL_BUDGET_EVIDENCE_TERM_LIMIT);
                for (const pid of tierMatches) {
                  addCandidate(pid, "material_budget_tier", 0, undefined, undefined, SOURCE_SCORE_MATERIAL_BUDGET_TIER);
                  const cur = candidatesById.get(pid);
                  if (cur && evidenceTerms.length > 0) {
                    cur.material_budget_tier_terms = evidenceTerms;
                  }
                }
              }
            }
          }
        }
      } catch {
        warnings.push("material_budget_tier_skipped");
      }
    }

    // ========================================
    // SOURCE 12: STRUCTURAL_TYPE_MATCH (v2.0.0)
    // Match structural keywords to foundation_type to projects via project_building_specs
    // ========================================
    if (transcript_text) {
      try {
        const transcriptLower = transcript_text.toLowerCase();
        const matchedFoundationTypes = new Set<string>();

        for (const [keyword, foundationType] of Object.entries(STRUCTURAL_KEYWORD_MAP)) {
          if (findTermInText(transcriptLower, keyword) >= 0) {
            matchedFoundationTypes.add(foundationType);
          }
        }

        if (matchedFoundationTypes.size > 0) {
          const { data: specRows } = await db
            .from("project_building_specs")
            .select("project_id, foundation_type")
            .in("foundation_type", Array.from(matchedFoundationTypes));

          if (specRows?.length) {
            const specProjectIds = specRows.map((r) => r.project_id);
            const { data: activeProjects } = await db
              .from("projects")
              .select("id")
              .in("id", specProjectIds)
              .in("status", VALID_PROJECT_STATUSES)
              .eq("project_kind", VALID_PROJECT_KIND);

            const activeIds = new Set((activeProjects || []).map((p) => p.id));
            const matchedProjects = specRows.filter((r) => activeIds.has(r.project_id));

            if (matchedProjects.length > 0) {
              sources_used.push("structural_type_match");
              const score = matchedProjects.length === 1
                ? SOURCE_SCORE_STRUCTURAL_TYPE_SINGLE
                : SOURCE_SCORE_STRUCTURAL_TYPE_MULTI;

              for (const r of matchedProjects) {
                addCandidate(r.project_id, "structural_type_match", 0, undefined, undefined, score);
                const cur = candidatesById.get(r.project_id);
                if (cur) {
                  cur.alias_matches.push({
                    term: `foundation:${r.foundation_type}`,
                    match_type: "structural_type",
                  });
                }
              }
            }
          }
        }
      } catch {
        warnings.push("structural_type_match_skipped");
      }
    }

    // ========================================
    // CONTINUITY BUNDLE (Back-to-back calls within 48h)
    // Tiered linking: TIER_1 project mention, TIER_2 callback phrase, TIER_3 recency
    // Floater rule: if floater or gap > 4h, require TIER_1
    // ========================================
    if (contact_id && event_at_utc && transcript_text) {
      try {
        const eventMs = Date.parse(event_at_utc);
        if (!Number.isNaN(eventMs)) {
          const sinceIso = new Date(eventMs - CONTINUITY_LOOKBACK_HOURS * 60 * 60 * 1000).toISOString();
          const continuityPriorColumns = DISABLE_INTERACTION_PROJECT_ID_FALLBACKS
            ? "interaction_id, event_at_utc"
            : "interaction_id, project_id, event_at_utc";
          const { data: priorRows } = await db
            .from("interactions")
            .select(continuityPriorColumns)
            .eq("contact_id", contact_id)
            .lt("event_at_utc", event_at_utc)
            .gte("event_at_utc", sinceIso)
            .order("event_at_utc", { ascending: false })
            .limit(CONTINUITY_MAX_PRIOR_CALLS * 2);

          const projectIds = Array.from(
            new Set(
              (!DISABLE_INTERACTION_PROJECT_ID_FALLBACKS
                ? (priorRows || []).map((r) => r.project_id).filter(Boolean)
                : [])
                .map((id) => String(id)),
            ),
          );
          const priorProjectNames = new Map<string, string>();
          if (projectIds.length && !DISABLE_INTERACTION_PROJECT_ID_FALLBACKS) {
            const { data: pnameRows } = await db.from("projects").select("id, name").in("id", projectIds)
              .in("status", VALID_PROJECT_STATUSES)
              .eq("project_kind", VALID_PROJECT_KIND);
            for (const r of (pnameRows || [])) {
              if (r.id) priorProjectNames.set(r.id, r.name || r.id);
            }
          }

          const tierRank: Record<string, number> = { TIER_1: 0, TIER_2: 1, TIER_3: 2 };
          for (const row of (priorRows || [])) {
            if (!row.interaction_id || !row.event_at_utc) continue;
            const priorMs = Date.parse(row.event_at_utc);
            if (Number.isNaN(priorMs)) continue;
            const gapMinutes = Math.max(0, Math.round((eventMs - priorMs) / 60000));
            if (gapMinutes > CONTINUITY_LOOKBACK_HOURS * 60) continue;

            const isFloaterSensitive = floater_flag || gapMinutes > CONTINUITY_FLOATER_GAP_HOURS * 60;
            const hasProjectMention = projectMentionSpans.length > 0;
            const hasCallback = callbackSpans.length > 0;

            let tier: "TIER_1" | "TIER_2" | "TIER_3" = "TIER_3";
            let reason = "recency_only";
            if (hasCallback) {
              tier = "TIER_2";
              reason = "callback_phrase";
            }
            if (hasProjectMention) {
              tier = "TIER_1";
              reason = "project_mention";
            }

            // Floater rule: require Tier1
            if (isFloaterSensitive && tier !== "TIER_1") continue;

            const spans: string[] = [];
            if (tier === "TIER_1") spans.push(...projectMentionSpans.slice(0, 5));
            if (tier === "TIER_1" || tier === "TIER_2") spans.push(...callbackSpans.slice(0, 5));
            const trimmedSpans = spans.slice(0, 5).map((s) => s.slice(0, 80));

            continuity_links.push({
              prior_interaction_id: row.interaction_id,
              prior_project_id: DISABLE_INTERACTION_PROJECT_ID_FALLBACKS ? null : row.project_id || null,
              prior_project_name: DISABLE_INTERACTION_PROJECT_ID_FALLBACKS
                ? null
                : row.project_id
                ? priorProjectNames.get(row.project_id) || row.project_id
                : null,
              prior_event_at_utc: row.event_at_utc || null,
              gap_minutes: gapMinutes,
              tier,
              evidence: {
                reason,
                spans: trimmedSpans,
                callback_phrase_hits: callbackSpans,
              },
            });
          }

          continuity_links = continuity_links
            .sort((a, b) => {
              const tierDiff = tierRank[a.tier] - tierRank[b.tier];
              if (tierDiff !== 0) return tierDiff;
              return a.gap_minutes - b.gap_minutes;
            })
            .slice(0, CONTINUITY_MAX_PRIOR_CALLS);

          if (continuity_links.length > 0) {
            sources_used.push("continuity_bundle");
          }
        } else {
          warnings.push("continuity_no_event_time");
        }
      } catch (_contErr) {
        warnings.push("continuity_bundle_failed");
      }
    }

    // ========================================
    // GLOBAL BLOCKLIST ENFORCEMENT
    // Apply after all source aggregation, before ranking/truncation.
    // ========================================
    if (blockedProjectIds.size > 0 && candidatesById.size > 0) {
      let removed = 0;
      for (const pid of blockedProjectIds) {
        if (candidatesById.delete(pid)) removed += 1;
      }
      if (removed > 0) {
        warnings.push(`blocklist_filtered_global:${removed}`);
        console.log(`[context-assembly] Blocklist removed ${removed} aggregated candidates pre-rank`);
      }
    }

    // ========================================
    // P0 HOMEOWNER OVERRIDE GATE (deterministic)
    // - If SOURCE 1 produced a unique homeowner-linked project, force it.
    // - Escape hatch: skip force when transcript has explicit contradictory
    //   project anchors for a different project.
    // ========================================
    if (homeownerOverrideProjectId) {
      const homeownerCandidate = candidatesById.get(homeownerOverrideProjectId);
      if (!homeownerCandidate) {
        homeownerOverrideSkippedReason = homeownerOverrideSkippedReason || "homeowner_candidate_missing";
        warnings.push("homeowner_override_candidate_missing");
      } else {
        const contradiction = findHomeownerOverrideConflict(
          homeownerOverrideProjectId,
          Array.from(candidatesById.entries()).map(([project_id, meta]) => ({
            project_id,
            alias_matches: meta.alias_matches,
          })),
        );

        if (contradiction) {
          homeownerOverrideConflictProjectId = contradiction.project_id;
          homeownerOverrideConflictTerm = contradiction.term;
          homeownerOverrideSkippedReason = "explicit_contradictory_anchor";
          warnings.push(`homeowner_override_skipped_conflict:${contradiction.project_id}`);
        } else {
          const removedIds = Array.from(candidatesById.keys()).filter((pid) => pid !== homeownerOverrideProjectId);
          for (const pid of removedIds) {
            candidatesById.delete(pid);
          }
          addCandidate(
            homeownerOverrideProjectId,
            "homeowner_override",
            0,
            undefined,
            undefined,
            SOURCE_SCORE_HOMEOWNER_OVERRIDE,
          );
          const forced = candidatesById.get(homeownerOverrideProjectId);
          if (forced) forced.assigned = true;
          homeownerOverrideApplied = true;
          sources_used.push("homeowner_override");
          if (removedIds.length > 0) {
            warnings.push(`homeowner_override_forced:${removedIds.length}`);
          }
        }
      }
    }

    // ========================================
    // CLIENT OVERRIDE GATE (deterministic)
    // - If project_clients produced a unique client-linked project, force it.
    // - Same escape hatch as homeowner: skip when transcript has explicit
    //   contradictory project anchors for a different project.
    // - Skipped if homeowner override already applied.
    // ========================================
    if (clientOverrideProjectId && !homeownerOverrideApplied) {
      const clientCandidate = candidatesById.get(clientOverrideProjectId);
      if (!clientCandidate) {
        clientOverrideSkippedReason = clientOverrideSkippedReason ||
          "client_candidate_missing";
        warnings.push("client_override_candidate_missing");
      } else {
        const contradiction = findHomeownerOverrideConflict(
          clientOverrideProjectId,
          Array.from(candidatesById.entries()).map(([project_id, meta]) => ({
            project_id,
            alias_matches: meta.alias_matches,
          })),
        );

        if (contradiction) {
          clientOverrideConflictProjectId = contradiction.project_id;
          clientOverrideConflictTerm = contradiction.term;
          clientOverrideSkippedReason = "explicit_contradictory_anchor";
          warnings.push(
            `client_override_skipped_conflict:${contradiction.project_id}`,
          );
        } else {
          const removedIds = Array.from(candidatesById.keys()).filter(
            (pid) => pid !== clientOverrideProjectId,
          );
          for (const pid of removedIds) {
            candidatesById.delete(pid);
          }
          addCandidate(
            clientOverrideProjectId,
            "client_override",
            0,
            undefined,
            undefined,
            SOURCE_SCORE_HOMEOWNER_OVERRIDE,
          );
          const forced = candidatesById.get(clientOverrideProjectId);
          if (forced) forced.assigned = true;
          clientOverrideApplied = true;
          sources_used.push("client_override");
          if (removedIds.length > 0) {
            warnings.push(`client_override_forced:${removedIds.length}`);
          }
        }
      }
    }

    // ========================================
    // ENRICH CANDIDATES WITH PROJECT DETAILS
    // ========================================
    const candidateIds = Array.from(candidatesById.keys());
    const projectDetailsById = new Map<string, {
      name: string;
      address: string | null;
      client_name: string | null;
      aliases: string[];
      status: string | null;
      phase: string | null;
    }>();

    if (candidateIds.length) {
      const { data: prows } = await db
        .from("projects")
        .select("id, name, address, client_name, aliases, status, phase")
        .in("id", candidateIds);

      if (prows) {
        for (const p of prows) {
          if (p.id) {
            projectDetailsById.set(p.id, {
              name: p.name || p.id,
              address: p.address || null,
              client_name: p.client_name || null,
              aliases: Array.isArray(p.aliases) ? p.aliases : [],
              status: p.status || null,
              phase: p.phase || null,
            });
          }
        }
      }

      try {
        const { data: enrichAliasRows, error: aliasErr } = await db
          .from("v_project_alias_lookup")
          .select("project_id, alias")
          .in("project_id", candidateIds);

        if (!aliasErr && enrichAliasRows) {
          for (const r of enrichAliasRows) {
            if (r.project_id && r.alias) {
              const details = projectDetailsById.get(r.project_id);
              if (details && !details.aliases.includes(r.alias)) {
                details.aliases.push(r.alias);
              }
            }
          }
        }
      } catch {
        // View doesn't exist
      }
    }

    // ========================================
    // BUILD CANDIDATES ARRAY
    // PHONETIC-ADJACENT-ONLY: classify match strength, flag weak-only candidates
    // ========================================
    const candidates: Candidate[] = [];

    for (const [pid, meta] of candidatesById) {
      const details = projectDetailsById.get(pid);
      if (!details) continue;

      // Classify each alias match as strong or weak
      const hasAliasEvidence = meta.alias_matches.length > 0;
      const hasStrongMatch = meta.alias_matches.some(
        (m) => classifyMatchStrength(m.term, m.match_type, details.name) === "strong",
      );
      const projectNameTokens = tokenizeTextForOverlap(details.name).map((t) => t.toLowerCase());
      const hasCommonWordAliasInName = projectNameTokens.some((t) => COMMON_WORD_ALIAS_TERMS.has(t));
      const hasHighConfidenceCorroboration = meta.sources.some((src) =>
        src === "rpc_scan_transcript_for_projects" ||
        src === "cross_contact_claim_match" ||
        src === "interactions_existing_project"
      );
      const commonWordAliasDemoted = mysteryWhiteMaterialMentioned &&
        hasCommonWordAliasInName &&
        !hasHighConfidenceCorroboration;
      const weakOnly = (hasAliasEvidence && !hasStrongMatch && !meta.assigned) || commonWordAliasDemoted;

      if (weakOnly) {
        warnings.push(`weak_alias_only:${details.name}`);
      }
      if (commonWordAliasDemoted) {
        warnings.push(`common_word_alias_demoted:${details.name}`);
      }
      const sourceScores = { ...meta.source_scores };
      let sourceStrength = meta.source_strength;
      if (commonWordAliasDemoted) {
        sourceScores.common_word_alias_demotion = -SOURCE_SCORE_COMMON_WORD_ALIAS_DEMOTION;
        sourceStrength = Math.max(0, sourceStrength - SOURCE_SCORE_COMMON_WORD_ALIAS_DEMOTION);
      }

      candidates.push({
        project_id: pid,
        project_name: details.name,
        address: details.address,
        client_name: details.client_name,
        aliases: details.aliases,
        status: details.status,
        phase: details.phase,
        evidence: {
          sources: meta.sources,
          affinity_weight: meta.affinity_weight,
          assigned: meta.assigned,
          alias_matches: meta.alias_matches,
          source_scores: sourceScores,
          source_strength: sourceStrength,
          geo_distance_km: meta.geo_distance_km,
          geo_signal: meta.geo_signal,
          claim_content_match_terms: meta.claim_content_match_terms?.slice(0, CLAIM_CONTENT_EVIDENCE_TERM_LIMIT),
          cross_contact_claim_match_terms: meta.cross_contact_claim_match_terms?.slice(
            0,
            CROSS_CONTACT_EVIDENCE_TERM_LIMIT,
          ),
          material_budget_tier_terms: meta.material_budget_tier_terms?.slice(0, MATERIAL_BUDGET_EVIDENCE_TERM_LIMIT),
          weak_only: weakOnly || undefined,
          common_word_alias_demoted: commonWordAliasDemoted || undefined,
          corroboration_count: countCorroborationCategories(
            meta.sources,
            meta.assigned,
            !!(meta.geo_signal && meta.geo_signal.score > 0),
          ),
        },
      });
    }

    // Sort by evidence strength
    // Priority: assigned > weak_only > corroboration > alias_matches > source_strength > claim_crossref > affinity_weight > geo
    // v2.1.0: source_strength (transcript evidence quality) now ranks ABOVE affinity_weight
    // v2.2.0: claim_crossref (journal semantic overlap) now ranks after source_strength.
    const sortCandidates = (list: Candidate[]) =>
      list.sort((a, b) => {
        if (a.evidence.assigned !== b.evidence.assigned) return a.evidence.assigned ? -1 : 1;
        // Strong evidence beats weak evidence
        const aWeak = a.evidence.weak_only === true;
        const bWeak = b.evidence.weak_only === true;
        if (aWeak !== bWeak) return aWeak ? 1 : -1;
        const aDemoted = a.evidence.common_word_alias_demoted === true;
        const bDemoted = b.evidence.common_word_alias_demoted === true;
        if (aDemoted !== bDemoted) return aDemoted ? 1 : -1;
        // v2.3.0: multi-source corroboration ranks above single-source
        const aCorr = (a.evidence.corroboration_count || 0) >= 2 ? 1 : 0;
        const bCorr = (b.evidence.corroboration_count || 0) >= 2 ? 1 : 0;
        if (bCorr !== aCorr) return bCorr - aCorr;
        if (b.evidence.alias_matches.length !== a.evidence.alias_matches.length) {
          return b.evidence.alias_matches.length - a.evidence.alias_matches.length;
        }
        // source_strength (transcript evidence quality) before affinity_weight (call frequency)
        const aSourceStrength = a.evidence.source_strength || 0;
        const bSourceStrength = b.evidence.source_strength || 0;
        if (bSourceStrength !== aSourceStrength) {
          return bSourceStrength - aSourceStrength;
        }
        const aCrossref = a.evidence.claim_crossref_score || 0;
        const bCrossref = b.evidence.claim_crossref_score || 0;
        if (bCrossref !== aCrossref) {
          return bCrossref - aCrossref;
        }
        if (b.evidence.affinity_weight !== a.evidence.affinity_weight) {
          return b.evidence.affinity_weight - a.evidence.affinity_weight;
        }
        const aGeoScore = a.evidence.geo_signal?.score || 0;
        const bGeoScore = b.evidence.geo_signal?.score || 0;
        if (bGeoScore !== aGeoScore) return bGeoScore - aGeoScore;
        const aGeoOnly = a.evidence.sources.length === 1 && a.evidence.sources[0] === "geo_proximity";
        const bGeoOnly = b.evidence.sources.length === 1 && b.evidence.sources[0] === "geo_proximity";
        if (aGeoOnly !== bGeoOnly) return aGeoOnly ? 1 : -1;
        if (a.evidence.geo_distance_km !== undefined && b.evidence.geo_distance_km !== undefined) {
          return a.evidence.geo_distance_km - b.evidence.geo_distance_km;
        }
        return 0;
      });
    sortCandidates(candidates);

    const effectiveMaxCandidates = isInternalFloater ? MAX_CANDIDATES_FLOATER : MAX_CANDIDATES;
    const crossrefPoolSize = Math.min(candidates.length, effectiveMaxCandidates + 6);
    if (candidates.length > crossrefPoolSize) {
      truncations.push(`crossref_pool_capped_at_${crossrefPoolSize}`);
    }
    const candidatePool = candidates.slice(0, crossrefPoolSize);
    let finalCandidates = candidatePool.slice(0, effectiveMaxCandidates);

    // ========================================
    // SMART TRUNCATION OF TRANSCRIPT
    // ========================================
    const { text: finalTranscript, truncated } = smartTruncate(
      transcript_text,
      matchPositions,
      MAX_TRANSCRIPT_CHARS,
    );

    if (truncated) {
      truncations.push(`transcript_windowed_around_${matchPositions.length}_matches`);
    }

    // ========================================
    // v1.4.0: JOURNAL-DERIVED PROJECT STATE
    // Fetch active claims and open loops for each candidate project
    // This gives the ai-router knowledge of what's currently happening
    // on each candidate project (the "world model" context).
    // Non-fatal: if journal tables are empty or query fails, we skip.
    // ========================================
    const project_journal: ProjectJournalState[] = [];
    const candidateProjectIds = candidatePool.map((c) => c.project_id).filter(Boolean);

    if (candidateProjectIds.length > 0) {
      try {
        // Null-contact calls are unanchored; skip journal context to prevent cross-contact leakage.
        if (!contact_id) {
          warnings.push("journal_source_unanchored_skipped");
        } else {
          if (isInternalFloater) {
            warnings.push("journal_floater_unscoped");
          }
          // Pull a larger pool, then apply contact scoping before per-project caps.
          const { data: claimsData, error: claimsErr } = await db
            .from("journal_claims")
            .select("project_id, call_id, claim_type, claim_text, epistemic_status, created_at")
            .in("project_id", candidateProjectIds)
            .eq("active", true)
            .eq("claim_confirmation_state", "confirmed")
            .order("created_at", { ascending: false })
            .limit(candidateProjectIds.length * 25);

          const { data: loopsData, error: loopsErr } = await db
            .from("journal_open_loops")
            .select("project_id, call_id, loop_type, description, status, created_at")
            .in("project_id", candidateProjectIds)
            .eq("status", "open")
            .order("created_at", { ascending: false })
            .limit(candidateProjectIds.length * 12);

          if (!claimsErr && !loopsErr) {
            const callIds = Array.from(
              new Set([
                ...(claimsData || []).map((c) => c.call_id).filter(Boolean),
                ...(loopsData || []).map((l) => l.call_id).filter(Boolean),
              ] as string[]),
            );

            const sourceCalls = new Map<string, { contact_id: string | null; contact_phone: string | null }>();
            if (callIds.length > 0) {
              const { data: sourceCallRows } = await db
                .from("interactions")
                .select("interaction_id, contact_id, contact_phone")
                .in("interaction_id", callIds);

              for (const row of (sourceCallRows || [])) {
                sourceCalls.set(row.interaction_id, {
                  contact_id: row.contact_id,
                  contact_phone: row.contact_phone,
                });
              }
            }

            let scopedClaimsAdded = 0;
            let scopedLoopsAdded = 0;

            // Group claims by project
            const claimsByProject = new Map<string, JournalClaim[]>();
            for (const c of (claimsData || [])) {
              if (!c.project_id) continue;
              const source = c.call_id ? sourceCalls.get(c.call_id) : undefined;
              if (!source) continue;
              // Floater modifier: internal floaters see all project claims (unscoped)
              if (
                !isInternalFloater &&
                !matchesJournalSourceContact(contact_id, contact_phone, source.contact_id, source.contact_phone)
              ) {
                continue;
              }
              if (!claimsByProject.has(c.project_id)) claimsByProject.set(c.project_id, []);
              const arr = claimsByProject.get(c.project_id)!;
              if (arr.length < 5) { // Cap at 5 per project
                arr.push({
                  claim_type: c.claim_type,
                  claim_text: (c.claim_text || "").slice(0, 200),
                  epistemic_status: c.epistemic_status,
                  created_at: c.created_at,
                });
                scopedClaimsAdded += 1;
              }
            }

            // Group open loops by project
            const loopsByProject = new Map<string, JournalOpenLoop[]>();
            for (const l of (loopsData || [])) {
              if (!l.project_id) continue;
              const source = l.call_id ? sourceCalls.get(l.call_id) : undefined;
              if (!source) continue;
              // Floater modifier: internal floaters see all project loops (unscoped)
              if (
                !isInternalFloater &&
                !matchesJournalSourceContact(contact_id, contact_phone, source.contact_id, source.contact_phone)
              ) {
                continue;
              }
              if (!loopsByProject.has(l.project_id)) loopsByProject.set(l.project_id, []);
              const arr = loopsByProject.get(l.project_id)!;
              if (arr.length < 3) { // Cap at 3 per project
                arr.push({
                  loop_type: l.loop_type,
                  description: (l.description || "").slice(0, 200),
                  status: l.status,
                });
                scopedLoopsAdded += 1;
              }
            }

            // Build per-project state
            let journalSourceAdded = false;
            for (const pid of candidateProjectIds) {
              const claims = claimsByProject.get(pid) || [];
              const loops = loopsByProject.get(pid) || [];

              if (claims.length > 0 || loops.length > 0) {
                project_journal.push({
                  project_id: pid,
                  active_claims_count: claims.length, // Note: this is capped at 5, actual count may be higher
                  recent_claims: claims,
                  open_loops: loops,
                  last_journal_activity: claims.length > 0 ? claims[0].created_at : null,
                });
                if (!journalSourceAdded) {
                  sources_used.push("journal_claims");
                  journalSourceAdded = true;
                }
              }
            }

            if (scopedClaimsAdded === 0 && scopedLoopsAdded === 0) {
              warnings.push("journal_contact_scope_no_matches");
            }
          }
        }
      } catch (_journalErr) {
        // Non-fatal: journal tables may not be populated yet
        warnings.push("journal_state_skipped");
      }
    }

    // ========================================
    // SOURCE 13: CLAIM_CROSSREF_RERANK (v2.2.0)
    // Semantic journal/transcript overlap on candidate pool.
    // Re-ranks candidates before final cap and emits compact evidence pointers.
    // ========================================
    if (candidatePool.length > 0 && project_journal.length > 0 && finalTranscript) {
      const allClaims = project_journal.flatMap((pj) =>
        (pj.recent_claims || []).map((claim) => ({
          project_id: pj.project_id,
          claim_text: claim.claim_text,
          claim_type: claim.claim_type,
        }))
      );

      if (allClaims.length > 0) {
        const crossrefResults = computeClaimCrossref(
          finalTranscript,
          candidatePool.map((c) => ({
            project_id: c.project_id,
            project_name: c.project_name,
          })),
          allClaims,
        );

        const byProject = new Map(crossrefResults.map((r) => [r.project_id, r]));
        let anyCrossrefSignal = false;
        for (const candidate of candidatePool) {
          const result = byProject.get(candidate.project_id);
          if (!result) continue;
          const score = Number(result.claim_crossref_score || 0);
          if (score > 0) anyCrossrefSignal = true;
          candidate.evidence.claim_crossref_score = score;
          candidate.evidence.claim_crossref_topics = (result.matching_topics || []).slice(0, 5);
          candidate.evidence.claim_crossref_snippets = (result.matching_claims || [])
            .slice(0, 3)
            .map((c) => String(c.claim_text || "").replace(/\s+/g, " ").trim().slice(0, 100))
            .filter(Boolean);
        }

        if (anyCrossrefSignal) {
          sources_used.push("claim_crossref_rerank");
          sortCandidates(candidatePool);
          finalCandidates = candidatePool.slice(0, effectiveMaxCandidates);
        }
      }
    }

    if (candidatePool.length > effectiveMaxCandidates) {
      truncations.push(`candidates_capped_at_${effectiveMaxCandidates}`);
    }

    const finalCandidateIdSet = new Set(finalCandidates.map((c) => c.project_id));
    const finalProjectJournal = project_journal.filter((pj) => finalCandidateIdSet.has(pj.project_id));

    // ========================================
    // SOURCE 14: PROJECT_FACTS (World model) (v2.2.0; feature-flagged)
    // Time-aware, provenance-backed facts per candidate project.
    //
    // Hard constraints:
    // - Default to KNOWN_AS_OF (as_of_at <= t_call AND observed_at <= t_call)
    // - Same-call exclusion (drop any facts sourced from this interaction)
    // ========================================
    let project_facts: ProjectFactsPack[] | undefined;
    if (WORLD_MODEL_FACTS_ENABLED && finalCandidates.length > 0 && event_at_utc) {
      try {
        // Best-effort: gather evidence_event_id(s) for the current call so we can exclude them too.
        const { data: evidenceRows } = await db
          .from("evidence_events")
          .select("evidence_event_id")
          .eq("source_type", "call")
          .eq("source_id", interaction_id);
        const currentEvidenceEventIds = new Set(
          (evidenceRows || []).map((r: any) => String(r.evidence_event_id || "")).filter(Boolean),
        );

        const candidateProjectIds = finalCandidates.map((c) => c.project_id);
        const maxRows = WORLD_MODEL_FACTS_MAX_PER_PROJECT * candidateProjectIds.length * 3;

        const { data: factRows, error: factsErr } = await db
          .from("project_facts")
          .select("project_id, as_of_at, observed_at, fact_kind, fact_payload, evidence_event_id, interaction_id")
          .in("project_id", candidateProjectIds)
          .lte("as_of_at", event_at_utc)
          .lte("observed_at", event_at_utc)
          .order("as_of_at", { ascending: false })
          .order("observed_at", { ascending: false })
          .limit(maxRows);

        if (factsErr) {
          warnings.push("project_facts_fetch_failed");
        } else if (factRows && factRows.length > 0) {
          const byProject = new Map<string, ProjectFactRow[]>();
          for (const row of factRows as any[]) {
            const rowInteractionId = row.interaction_id ? String(row.interaction_id) : null;
            const rowEvidenceEventId = row.evidence_event_id ? String(row.evidence_event_id) : null;

            // Mandatory same-call exclusion (interaction_id OR evidence_event_id match).
            if (rowInteractionId && rowInteractionId === interaction_id) continue;
            if (rowEvidenceEventId && currentEvidenceEventIds.has(rowEvidenceEventId)) continue;

            const pid = String(row.project_id);
            if (!byProject.has(pid)) byProject.set(pid, []);
            byProject.get(pid)!.push({
              project_id: pid,
              as_of_at: String(row.as_of_at),
              observed_at: String(row.observed_at),
              fact_kind: String(row.fact_kind),
              fact_payload: row.fact_payload,
              evidence_event_id: rowEvidenceEventId,
              interaction_id: rowInteractionId,
            });
          }

          project_facts = candidateProjectIds.map((pid) => ({
            project_id: pid,
            facts: (byProject.get(pid) || []).slice(0, WORLD_MODEL_FACTS_MAX_PER_PROJECT),
          }));

          const anyFacts = project_facts.some((p) => p.facts.length > 0);
          if (anyFacts) sources_used.push("project_facts");
        }
      } catch (_factsErr) {
        warnings.push("project_facts_skipped");
      }
    }

    // ========================================
    // BUILD CONTEXT PACKAGE
    // ========================================
    const context_package: ContextPackage = {
      meta: {
        assembly_version: ASSEMBLY_VERSION,
        selection_rules_version: SELECTION_RULES_VERSION,
        span_id,
        interaction_id: interaction_id!,
        assembled_at_utc: new Date().toISOString(),
        truncations,
        warnings,
        sources_used,
        homeowner_override: homeownerOverrideApplied,
        homeowner_override_project_id: homeownerOverrideProjectId,
        homeowner_override_conflict_project_id: homeownerOverrideConflictProjectId,
        homeowner_override_conflict_term: homeownerOverrideConflictTerm,
        homeowner_override_skipped_reason: homeownerOverrideSkippedReason,
        client_override: clientOverrideApplied,
        client_override_project_id: clientOverrideProjectId,
        client_override_conflict_project_id: clientOverrideConflictProjectId,
        client_override_conflict_term: clientOverrideConflictTerm,
        client_override_skipped_reason: clientOverrideSkippedReason,
      },
      span: {
        start_ms,
        end_ms,
        transcript_text: finalTranscript,
        words,
      },
      contact: {
        contact_id,
        contact_name,
        phone_e164_last4,
        floater_flag,
        fanout_class,
        effective_fanout,
        recent_projects,
      },
      candidates: finalCandidates,
      place_mentions,
      project_journal: finalProjectJournal,
      ...(project_facts ? { project_facts } : {}),
      email_context,
      email_lookup_meta,
      continuity_links,
    };

    return new Response(
      JSON.stringify({
        ok: true,
        context_package,
        ms: Date.now() - t0,
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      },
    );
  } catch (e: any) {
    console.error("context-assembly error:", e.message);
    return new Response(
      JSON.stringify({
        ok: false,
        error_code: "internal_error",
        error: e.message,
        version: ASSEMBLY_VERSION,
        ms: Date.now() - t0,
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
