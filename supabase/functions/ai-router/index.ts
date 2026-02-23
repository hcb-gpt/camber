/**
 * ai-router Edge Function v1.15.0
 * LLM-based project attribution for conversation spans
 *
 * @version 1.15.1
 * @date 2026-02-17
 * @purpose Use Claude Haiku to attribute spans to projects with anchored evidence
 *
 * v1.15.1 Changes (stopline: no unanchored assignments):
 * - Enforces fail-closed provenance gate for decision='assign':
 *   require transcript anchor pointers OR world-model fact provenance pointers.
 * - Persists provenance payload to span_attributions.matched_terms + match_positions.
 * - Emits stopline failure tags when assignments are downgraded to review.
 *
 * v1.15.0 Changes (3-band decision policy):
 * - Replaces 2-band confidence gate (assign/none) with 3-band (assign/review/none).
 * - Lowers THRESHOLD_REVIEW from 0.50 to 0.25, widening the review band and shrinking "none".
 * - Adds safe low-confidence assign path: promotes review→assign when confidence >= 0.40
 *   AND guardrails are satisfied (anchored contact + strong alias, or smoking_gun tier).
 * - Updates prompt to instruct LLM to always include best candidate in review decisions.
 * - Adds candidate_project_id to review_queue context_payload for downstream processing.
 *
 * CORE PRINCIPLE: span_attributions is the single source of truth.
 * NO writes to interactions.project_id from this path.
 *
 * v1.14.0 Changes (world model facts evidence; feature-flagged):
 * - Adds optional world-model facts prompt surface per candidate project when WORLD_MODEL_FACTS_ENABLED=true.
 * - Adds deterministic corroboration guardrail: world-model fact references can support assignment
 *   only when references map to strong fact anchors and do not contradict transcript context.
 * - Adds optional model output field `world_model_references[]` for citation of influencing facts.
 *
 * v1.14.0 Changes (junk-call prefilter):
 * - Adds conservative junk-call prefilter (voicemail / connection-failure / minimal-content patterns).
 * - For junk spans, forces decision='none' with needs_review=false and reasoning tagged with junk_call_filtered.
 * - Keeps fail-open behavior for substantive snippets and fail-closed behavior for attribution/review queue writes.
 *
 * v1.13.0 Changes (deterministic homeowner override gate v1):
 * - Adds deterministic homeowner/client override in normal inference flow
 *   (after evidence assembly, before final attribution write).
 * - Force-assigns homeowner override project when authoritative metadata is present,
 *   bypassing weak_anchor/geo_only and bizdev review detours.
 * - Explicitly skips deterministic override when span looks multi-project.
 *
 * v1.12.0 Changes (sanitization + deterministic homeowner fallback):
 * - Sanitizes transcript text before prompt/JSON packaging and retries once with stricter sanitization.
 * - Applies deterministic homeowner assignment fallback when LLM inference/parsing fails and
 *   homeowner override metadata is authoritative.
 * - Prevents fallback homeowner assignments from being routed into review_queue.
 *
 * v1.11.1 Changes (homeowner override strong-anchor equivalence):
 * - Treats context_package.meta.homeowner_override=true (without contradiction metadata)
 *   as a strong-anchor equivalent for gating/review-queue reason generation.
 * - Prevents weak_anchor / geo_only review reasons for deterministic homeowner overrides
 *   unless explicit contradiction metadata is present.
 *
 * v1.11.0 Changes (bizdev/prospect commitment gate):
 * - Added bizdev/prospect classifier with evidence tags from transcript terms
 * - Added commitment-to-start gate: bizdev spans cannot retain project_id without
 *   commitment evidence (contract/deposit/permit/PO/start-date language)
 * - Added bizdev classifier details to review_queue context + API response guardrails
 *
 * v1.10.0 Changes (common-word alias corroboration guardrail):
 * - Added guardrail to downgrade assign->review when chosen project is supported
 *   only by common-word/material aliases (for example "white", "mystery white")
 * - Prompt now explicitly forbids auto-assign on uncorroborated common aliases
 * - Candidate prompt includes aliases that are treated as ambiguous/common-word
 * - Review queue reason codes now include common_alias_unconfirmed when triggered
 *
 * v1.9.0 Changes (source_strength in Evidence line):
 * - Prompt now includes source_strength per candidate in the Evidence line
 *   (was missing — LLM never saw transcript evidence quality scores)
 * - ContextPackage type updated to include source_strength field
 * - Prompt version bumped to v1.9.0 (content change)
 * - Pairs with context-assembly v2.1.0 sort fix (source_strength > affinity_weight)
 *
 * v1.8.1 Changes (Pipeline chain wiring):
 * - Added fire-and-forget chain call to journal-extract after span_attributions write
 *   (belt-and-suspenders with segment-call hook — ensures journal extraction runs
 *   even when ai-router is called outside the segment-call chain, e.g. backfill/replay)
 * - journal-extract fires for ALL decisions (assign/review/none) since it reads
 *   applied_project_id from span_attributions and handles null-project gracefully
 * - Response includes journal_extract_fired flag + function_version field
 *
 * v1.8.0 Changes (Gmail weak corroboration):
 * - Prompt includes bounded email_context summaries when present
 * - Explicitly treats email context as weak corroboration only
 *
 * v1.7.0 Changes (P1: Contact Fanout + Journal References):
 * - Prompt includes fanout_class + effective_fanout per contact (DATA-9 D4 spec)
 * - Prompt explains fanout signal strength (anchored=strong, floater=anti-signal)
 * - Output includes journal_references: which journal claims influenced the decision
 * - Replaces boolean floater_flag with richer fanout context
 *
 * Input:
 *   - context_package: ContextPackage (from context-assembly)
 *   - dry_run?: boolean (if true, don't persist to DB)
 *
 * Output:
 *   - span_id, project_id, confidence, decision, reasoning, anchors
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";
import { evaluateJunkCallPrefilter } from "../_shared/junk_call_prefilter.ts";
import { parseLlmJson } from "../_shared/llm_json.ts";
import { applyCommonAliasCorroborationGuardrail, isCommonWordAlias } from "./alias_guardrails.ts";
import { applyBethanyRoadWinshipGuardrail } from "./bethany_winship_guardrail.ts";
import { applyBizDevCommitmentGate } from "./bizdev_guardrails.ts";
import { evaluateHomeownerOverride } from "./homeowner_override_gate.ts";
import {
  applyWorldModelReferenceGuardrail,
  buildWorldModelFactsCandidateSummary,
  filterProjectFactsForPrompt,
  parseBoolEnv,
  parseWorldModelReferences,
  type ProjectFactsPack,
  type WorldModelReference,
} from "./world_model_facts.ts";

const PROMPT_VERSION_BASE = "v1.13.0";
const FUNCTION_VERSION = "v1.15.1";
const MODEL_ID = Deno.env.get("AI_ROUTER_MODEL") || "claude-3-haiku-20240307";
const MAX_TOKENS = 1024;
const WORLD_MODEL_FACTS_ENABLED = parseBoolEnv(Deno.env.get("WORLD_MODEL_FACTS_ENABLED"), false);
const WORLD_MODEL_FACTS_MAX_PER_PROJECT = Math.max(
  0,
  Math.min(50, Number.parseInt(Deno.env.get("WORLD_MODEL_FACTS_MAX_PER_PROJECT") || "20", 10) || 20),
);
const PROMPT_VERSION = WORLD_MODEL_FACTS_ENABLED ? "v1.12.0_world_model_facts" : PROMPT_VERSION_BASE;

// Confidence thresholds (3-band policy v1.15.0)
const THRESHOLD_AUTO_ASSIGN = 0.75;
const THRESHOLD_REVIEW = 0.25;
const THRESHOLD_SAFE_LOW_ASSIGN = 0.40;

// Defense-in-depth: closed-project hard filter (mirrors context-assembly VALID_PROJECT_STATUSES)
const ATTRIBUTION_ELIGIBLE_STATUSES = new Set(["active", "warranty", "estimating"]);

// ============================================================
// TYPES
// ============================================================

interface Anchor {
  text: string;
  candidate_project_id: string | null;
  match_type: string;
  quote: string;
}

type PlaceRole = "proximity" | "origin" | "destination";

interface GeoSignal {
  score: number;
  dominant_role: PlaceRole;
  role_counts: Record<PlaceRole, number>;
  place_count: number;
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

interface SuggestedAlias {
  project_id: string;
  alias_term: string;
  rationale: string;
}

interface JournalReference {
  project_id: string;
  claim_type: string;
  claim_text: string;
  relevance: string;
}

interface AttributionResult {
  span_id: string;
  project_id: string | null;
  confidence: number;
  decision: "assign" | "review" | "none";
  reasoning: string;
  anchors: Anchor[];
  suggested_aliases?: SuggestedAlias[];
  journal_references?: JournalReference[];
  world_model_references?: WorldModelReference[];
}

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
  recent_claims: JournalClaim[];
  open_loops: JournalOpenLoop[];
  last_journal_activity: string | null;
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
  returned_count?: number;
  cached?: boolean;
  warnings?: string[];
  date_range?: string | null;
}

interface ContextPackage {
  meta: {
    span_id: string;
    interaction_id: string;
    [key: string]: any;
  };
  span: {
    transcript_text: string;
    [key: string]: any;
  };
  contact: {
    contact_id: string | null;
    contact_name: string | null;
    floater_flag: boolean;
    fanout_class?: string;
    effective_fanout?: number;
    recent_projects: Array<{ project_id: string; project_name: string }>;
  };
  candidates: Array<{
    project_id: string;
    project_name: string;
    address: string | null;
    client_name: string | null;
    aliases: string[];
    status: string | null;
    phase: string | null;
    evidence: {
      sources: string[];
      affinity_weight: number;
      source_strength?: number;
      assigned: boolean;
      alias_matches: Array<{ term: string; match_type: string; snippet?: string }>;
      geo_distance_km?: number;
      geo_signal?: GeoSignal;
    };
  }>;
  place_mentions?: PlaceMention[];
  project_journal?: ProjectJournalState[];
  project_facts?: ProjectFactsPack[];
  email_context?: EmailContextItem[];
  email_lookup_meta?: EmailLookupMeta | null;
  evidence_brief?: any;
}

interface ProvenancePointer {
  term: string;
  match_type: string;
  source: "transcript_anchor" | "project_fact";
  quote: string | null;
  char_start: number | null;
  char_end: number | null;
  candidate_project_id?: string | null;
  evidence_event_id?: string | null;
  fact_kind?: string | null;
  fact_as_of_at?: string | null;
}

type TranscriptSanitizeMode = "default" | "strict";

function sanitizeTranscriptText(
  text: string,
  mode: TranscriptSanitizeMode,
): { text: string; replaced: number } {
  const raw = String(text || "");
  let replaced = 0;
  // deno-lint-ignore no-control-regex -- intentional: scrub control chars from prompt-bound transcript text
  const pattern = mode === "strict" ? /[\x00-\x1F\x7F]/g : /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g;
  const scrubbed = raw.replace(pattern, () => {
    replaced += 1;
    return " ";
  });
  const normalized = mode === "strict" ? scrubbed.replace(/\s+/g, " ").trim() : scrubbed;
  return { text: normalized, replaced };
}

function withSanitizedTranscript(
  contextPackage: ContextPackage,
  mode: TranscriptSanitizeMode,
): { context: ContextPackage; replaced: number } {
  const sourceTranscript = contextPackage.span?.transcript_text || "";
  const sanitized = sanitizeTranscriptText(sourceTranscript, mode);

  if (sanitized.text === sourceTranscript) {
    return { context: contextPackage, replaced: sanitized.replaced };
  }

  return {
    context: {
      ...contextPackage,
      span: {
        ...(contextPackage.span || {}),
        transcript_text: sanitized.text,
      },
    },
    replaced: sanitized.replaced,
  };
}

function filterClosedProjectCandidates(
  ctx: ContextPackage,
): { filtered: ContextPackage; removed_count: number } {
  const candidates = Array.isArray(ctx.candidates) ? ctx.candidates : [];
  const kept = candidates.filter((c) => ATTRIBUTION_ELIGIBLE_STATUSES.has(String(c.status || "").trim().toLowerCase()));
  const removedCount = candidates.length - kept.length;
  if (removedCount === 0) return { filtered: ctx, removed_count: 0 };
  return {
    filtered: { ...ctx, candidates: kept },
    removed_count: removedCount,
  };
}

function deriveSpanDurationSeconds(contextPackage: ContextPackage): number | null {
  const startMs = Number(contextPackage.span?.start_ms);
  const endMs = Number(contextPackage.span?.end_ms);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) return null;
  if (endMs <= startMs) return null;
  return Math.round((endMs - startMs) / 1000);
}

// ============================================================
// GUARDRAIL HELPERS
// ============================================================

const HCB_STAFF_PATTERNS = [
  "zack sittler",
  "zachary sittler",
  "zach sittler",
  "chad barlow",
  "sittler:",
];

function anchorContainsStaffName(quote: string): boolean {
  const quoteLower = (quote || "").toLowerCase();
  for (const pattern of HCB_STAFF_PATTERNS) {
    if (quoteLower.includes(pattern)) {
      return true;
    }
  }
  if (/\bsittler\b/i.test(quote) && !/residence|project|house/i.test(quote)) {
    return true;
  }
  return false;
}

function normalizeForQuoteMatch(text: string): string {
  return (text || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[“”„‟‘’`"]/g, "")
    .replace(/[\-–—]/g, " ")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenizeForQuoteMatch(text: string): string[] {
  return normalizeForQuoteMatch(text)
    .split(" ")
    .map((token) => token.trim())
    .filter((token) => token.length > 0);
}

function levenshteinDistanceWithLimit(a: string, b: string, maxDistance: number): number {
  if (a.length === 0) return Math.min(b.length, maxDistance + 1);
  if (b.length === 0) return Math.min(a.length, maxDistance + 1);
  if (Math.abs(a.length - b.length) > maxDistance) return maxDistance + 1;

  const row = new Int32Array(b.length + 1);
  const prevRow = new Int32Array(b.length + 1);

  for (let j = 0; j <= b.length; j++) {
    prevRow[j] = j;
  }

  for (let i = 1; i <= a.length; i++) {
    row[0] = i;
    let bestInRow = row[0];

    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const value = Math.min(
        prevRow[j] + 1,
        row[j - 1] + 1,
        prevRow[j - 1] + cost,
      );
      row[j] = value;
      if (value < bestInRow) bestInRow = value;
    }

    if (bestInRow > maxDistance) {
      return maxDistance + 1;
    }

    prevRow.set(row);
  }

  return prevRow[b.length];
}

function hasFuzzyMatch(
  haystackTokens: string[],
  quoteNorm: string,
  quoteTokens: string[],
): boolean {
  const maxWindowDelta = Math.max(1, Math.floor(quoteTokens.length * 0.25));
  const minWindowLen = Math.max(1, quoteTokens.length - maxWindowDelta);
  const maxWindowLen = Math.min(haystackTokens.length, quoteTokens.length + maxWindowDelta);

  const maxDistance = Math.max(3, Math.floor(quoteNorm.length * 0.18));

  for (let windowLen = minWindowLen; windowLen <= maxWindowLen; windowLen++) {
    for (let i = 0; i + windowLen <= haystackTokens.length; i++) {
      const candidate = haystackTokens.slice(i, i + windowLen).join(" ");
      const distance = levenshteinDistanceWithLimit(quoteNorm, candidate, maxDistance);
      if (distance <= maxDistance) {
        return true;
      }
    }
  }

  return false;
}

function validateAnchorQuotes(
  anchors: Anchor[],
  transcript: string,
): { valid: boolean; validatedAnchors: Anchor[]; rejectedStaffAnchors: number } {
  if (!transcript || !anchors.length) {
    return { valid: false, validatedAnchors: [], rejectedStaffAnchors: 0 };
  }

  const transcriptNorm = normalizeForQuoteMatch(transcript);
  const transcriptTokens = tokenizeForQuoteMatch(transcriptNorm);

  const validatedAnchors: Anchor[] = [];
  let rejectedStaffAnchors = 0;

  for (const anchor of anchors) {
    if (!anchor.quote || anchor.quote.length === 0) continue;

    const quoteNorm = normalizeForQuoteMatch(anchor.quote);
    if (quoteNorm.length < 3) continue;

    if (anchorContainsStaffName(anchor.quote) || anchorContainsStaffName(anchor.text || "")) {
      rejectedStaffAnchors++;
      console.log(`[ai-router] Rejected staff-name anchor: "${anchor.quote}"`);
      continue;
    }

    const quoteTokens = tokenizeForQuoteMatch(quoteNorm);
    const exactMatch = transcriptNorm.includes(quoteNorm);
    const fuzzyMatch = !exactMatch && quoteTokens.length >= 3
      ? hasFuzzyMatch(transcriptTokens, quoteNorm, quoteTokens)
      : false;

    if (!exactMatch && !fuzzyMatch) {
      console.log(`[ai-router] Rejected anchor: quote not in transcript: "${anchor.quote}"`);
      continue;
    }

    const textNorm = normalizeForQuoteMatch(anchor.text || "");
    if (textNorm.length >= 3 && !quoteNorm.includes(textNorm)) {
      console.log(`[ai-router] Rejected anchor: text "${anchor.text}" not found in quote "${anchor.quote}"`);
      continue;
    }

    validatedAnchors.push(anchor);
  }

  return {
    valid: validatedAnchors.length > 0,
    validatedAnchors,
    rejectedStaffAnchors,
  };
}

const STRONG_ANCHOR_TYPES = [
  "exact_project_name",
  "alias",
  "address_fragment",
  "client_name",
  "chain_continuity",
];

const _WEAK_ANCHOR_TYPES = [
  "city_or_location",
  "mentioned_contact",
  "phonetic_or_pronunciation",
  "continuity_callback",
  "db_scan",
  "other",
];

function hasStrongAnchor(anchors: Anchor[]): boolean {
  return anchors.some((a) => STRONG_ANCHOR_TYPES.includes(a.match_type));
}

function uniqueStrings(values: string[]): string[] {
  return Array.from(new Set(values.map((v) => String(v || "").trim()).filter(Boolean)));
}

function firstCaseInsensitiveIndex(haystack: string, needle: string): number {
  if (!haystack || !needle) return -1;
  return haystack.toLowerCase().indexOf(needle.toLowerCase());
}

function buildTranscriptAnchorPointers(
  anchors: Anchor[],
  transcript: string,
  spanCharStart: number | null,
  spanCharEnd: number | null,
): ProvenancePointer[] {
  if (!transcript || !Array.isArray(anchors) || anchors.length === 0) return [];

  const pointers: ProvenancePointer[] = [];
  const seen = new Set<string>();

  for (const anchor of anchors) {
    const quote = String(anchor.quote || "").trim();
    const term = String(anchor.text || quote || "").trim();
    const primaryNeedle = quote || term;
    if (!primaryNeedle || primaryNeedle.length < 3) continue;

    let localStart = firstCaseInsensitiveIndex(transcript, primaryNeedle);
    let localNeedle = primaryNeedle;
    if (localStart < 0 && quote && term && term !== quote) {
      localStart = firstCaseInsensitiveIndex(transcript, term);
      localNeedle = term;
    }
    if (localStart < 0) continue;

    const localEnd = localStart + localNeedle.length;
    const absoluteStart = spanCharStart !== null ? spanCharStart + localStart : localStart;
    const absoluteEnd = spanCharStart !== null ? spanCharStart + localEnd : localEnd;

    if (spanCharStart !== null && spanCharEnd !== null) {
      if (absoluteStart < spanCharStart || absoluteEnd > spanCharEnd) continue;
    }

    const key = `${absoluteStart}:${absoluteEnd}:${term}:${anchor.match_type || "other"}`;
    if (seen.has(key)) continue;
    seen.add(key);

    pointers.push({
      term,
      match_type: anchor.match_type || "other",
      source: "transcript_anchor",
      quote: quote || null,
      char_start: absoluteStart,
      char_end: absoluteEnd,
      candidate_project_id: anchor.candidate_project_id || null,
    });
  }

  return pointers;
}

function buildProjectFactProvenancePointers(
  projectId: string | null,
  refs: WorldModelReference[] | undefined,
  projectFacts: ProjectFactsPack[],
): ProvenancePointer[] {
  if (!projectId || !Array.isArray(refs) || refs.length === 0 || !Array.isArray(projectFacts)) return [];
  const pack = projectFacts.find((p) => p.project_id === projectId);
  if (!pack || !Array.isArray(pack.facts) || pack.facts.length === 0) return [];

  const pointers: ProvenancePointer[] = [];
  const seen = new Set<string>();
  const refsForProject = refs.filter((r) => r.project_id === projectId);

  for (const ref of refsForProject) {
    const kind = String(ref.fact_kind || "").trim();
    if (!kind) continue;

    const candidates = pack.facts.filter((f) => f.fact_kind === kind);
    if (candidates.length === 0) continue;

    let fact = candidates.find((f) => ref.fact_as_of_at && f.as_of_at === ref.fact_as_of_at) ||
      candidates.find((f) => Boolean(f.evidence_event_id)) ||
      candidates[0];

    if (!fact?.evidence_event_id) continue;

    const key = `${fact.evidence_event_id}:${fact.fact_kind}:${fact.as_of_at}`;
    if (seen.has(key)) continue;
    seen.add(key);

    pointers.push({
      term: kind,
      match_type: "project_fact",
      source: "project_fact",
      quote: ref.fact_excerpt || null,
      char_start: null,
      char_end: null,
      candidate_project_id: projectId,
      evidence_event_id: fact.evidence_event_id,
      fact_kind: fact.fact_kind,
      fact_as_of_at: fact.as_of_at,
    });
  }

  return pointers;
}

/**
 * Derive attribution_source from anchor composition.
 * Values: llm_strong_anchor, llm_weak_anchor, llm_no_anchor, model_error
 */
function deriveAttributionSource(anchors: Anchor[], modelError: boolean): string {
  if (modelError) return "model_error";
  if (!anchors || anchors.length === 0) return "llm_no_anchor";
  if (hasStrongAnchor(anchors)) return "llm_strong_anchor";
  return "llm_weak_anchor";
}

/**
 * Derive evidence_tier from anchor strength + confidence.
 * Tier 1 = strong anchor + high confidence (>= 0.75)
 * Tier 2 = any anchor + medium confidence (>= 0.50)
 * Tier 3 = weak/no anchor or low confidence (< 0.50)
 */
function deriveEvidenceTier(anchors: Anchor[], confidence: number, modelError: boolean): number {
  if (modelError) return 3;
  const strong = hasStrongAnchor(anchors);
  if (strong && confidence >= 0.75) return 1;
  if (anchors.length > 0 && confidence >= 0.50) return 2;
  return 3;
}

/**
 * Safe low-confidence assign (v1.15.0 3-band policy).
 * Promotes review→assign when guardrails make it safe:
 * - Anchored contact (fanout=1) with at least one strong alias match on the chosen project
 * - Smoking_gun evidence tier on the chosen project
 * Requires confidence >= THRESHOLD_SAFE_LOW_ASSIGN (0.40).
 */
function evaluateSafeLowConfidenceAssign(opts: {
  decision: "assign" | "review" | "none";
  project_id: string | null;
  confidence: number;
  fanout_class: string;
  candidates: ContextPackage["candidates"];
}): { promoted: boolean; reason: string | null } {
  if (opts.decision !== "review" || !opts.project_id) {
    return { promoted: false, reason: null };
  }
  if (opts.confidence < THRESHOLD_SAFE_LOW_ASSIGN) {
    return { promoted: false, reason: null };
  }

  const chosen = opts.candidates.find((c) => c.project_id === opts.project_id);
  if (!chosen) return { promoted: false, reason: null };

  // Safe path 1: anchored contact with strong alias match on this project
  if (opts.fanout_class === "anchored") {
    const strongMatchTypes = new Set([
      "exact_project_name",
      "alias",
      "address_fragment",
      "client_name",
      "chain_continuity",
    ]);
    const hasStrongMatch = chosen.evidence.alias_matches.some((m) => strongMatchTypes.has(m.match_type));
    if (hasStrongMatch) {
      return { promoted: true, reason: "safe_anchored_contact_strong_match" };
    }
  }

  // Safe path 2: smoking_gun evidence tier
  const tierLabel = (chosen.evidence as any).evidence_tier_label;
  if (tierLabel === "smoking_gun") {
    return { promoted: true, reason: "safe_smoking_gun_tier" };
  }

  return { promoted: false, reason: null };
}

function canOverwriteLock(currentLock: string | null, newLock: string | null): boolean {
  const lockOrder: Record<string, number> = { "human": 3, "ai": 2 };
  const currentLevel = lockOrder[currentLock || ""] || 0;
  const newLevel = lockOrder[newLock || ""] || 0;
  return newLevel >= currentLevel;
}

// ============================================================
// REVIEW QUEUE HELPERS (PR-4)
// ============================================================

function buildReasonCodes(opts: {
  modelReasons?: string[] | null;
  quoteVerified: boolean;
  strongAnchor: boolean;
  modelError?: boolean;
  ambiguousContact?: boolean;
  geoOnly?: boolean;
  commonAliasUnconfirmed?: boolean;
  bizdevWithoutCommitment?: boolean;
  stoplineReason?: string | null;
}): string[] {
  const reasons: string[] = [];
  if (Array.isArray(opts.modelReasons)) reasons.push(...opts.modelReasons);

  if (!opts.quoteVerified) reasons.push("quote_unverified");
  if (!opts.strongAnchor) reasons.push("weak_anchor");
  if (opts.ambiguousContact) reasons.push("ambiguous_contact");
  if (opts.geoOnly) reasons.push("geo_only");
  if (opts.commonAliasUnconfirmed) reasons.push("common_alias_unconfirmed");
  if (opts.bizdevWithoutCommitment) reasons.push("bizdev_without_commitment");
  if (opts.stoplineReason) reasons.push(opts.stoplineReason);
  if (opts.modelError) reasons.push("model_error");

  return Array.from(new Set(reasons.filter(Boolean)));
}

async function upsertReviewQueue(
  db: any,
  payload: {
    span_id: string;
    interaction_id: string;
    reasons: string[];
    context_payload: Record<string, unknown>;
  },
): Promise<{ error: { message: string; details?: string } | null }> {
  const { error } = await db
    .from("review_queue")
    .upsert(
      {
        span_id: payload.span_id,
        interaction_id: payload.interaction_id,
        status: "pending",
        reason_codes: payload.reasons,
        reasons: payload.reasons,
        context_payload: payload.context_payload,
      },
      { onConflict: "span_id" },
    );

  if (error) {
    console.error("[ai-router] review_queue upsert failed:", error.message);
  }
  return { error };
}

async function resolveReviewQueue(
  db: any,
  spanId: string,
  notes: string,
): Promise<{ error: { message: string; details?: string } | null }> {
  const { error } = await db
    .from("review_queue")
    .update({
      status: "resolved",
      resolved_at: new Date().toISOString(),
      resolved_by: "ai-router",
      resolution_action: "confirmed",
      resolution_notes: notes,
    })
    .eq("span_id", spanId)
    .eq("status", "pending");

  if (error) {
    console.error("[ai-router] review_queue resolve failed:", error.message);
  }
  return { error };
}

// ============================================================
// PROMPT TEMPLATE
// ============================================================

const SYSTEM_PROMPT_BASE =
  `You are a project attribution specialist for HCB (Heartwood Custom Builders), a Georgia construction company.
Given a phone call transcript segment and candidate projects, determine which project (if any) the conversation is about.

CRITICAL - HCB STAFF EXCLUSION (HIGHEST PRIORITY):
The following are HCB STAFF/OWNERS who appear on MANY calls. They are NOT project clients:
- "Zack Sittler", "Zachary Sittler", "Zach Sittler" (owner/general contractor)
- "Chad Barlow" (owner)
- The word "Sittler" alone, when it refers to Zack

STRICT RULES FOR STAFF NAMES:
1. NEVER use any HCB staff name as an anchor quote
2. NEVER match staff names to similarly-named projects (e.g., "Sittler" in transcript does NOT indicate "Sittler Residence" project)
3. If the ONLY evidence for a project is a staff name match, output decision="review" or decision="none"
4. Speaker labels like "Zachary Sittler:" are NOT project evidence - they just identify who is speaking

RULES:
1. Look for explicit mentions of project names, addresses (including partial addresses like street names), CLIENT names (not staff), or known aliases in the transcript
2. The caller's project assignments (assigned=true) and call history (affinity) are SECONDARY signals - use them only when transcript evidence is ambiguous
3. CONTACT FANOUT determines how much weight to give the contact's identity:
   - anchored (fanout=1): Contact works on ONE project. Their identity is a STRONG attribution signal (near smoking gun)
   - semi_anchored (fanout=2): Useful with corroboration from transcript
   - drifter (fanout=3-4): Contextual only, needs strong transcript grounding
   - floater (fanout>=5): ANTI-SIGNAL. Treat like HCB staff for attribution — prioritize transcript anchors only
   - unknown (fanout=0): No project association — no signal from identity
4. If multiple projects are mentioned, choose the PRIMARY topic of discussion
5. If uncertain but you have a candidate, choose "review" with confidence 0.25-0.74 and ALWAYS include your best project_id guess
6. Only choose "none" with confidence <0.25 when the transcript has truly NO project-related content (admin, overhead, wrong number, etc.)
7. Common-word/material aliases (for example color/material terms like "white", "mystery white", "granite") are ambiguous and CANNOT be sole evidence for decision="assign"
8. If a common-word alias appears, require corroboration in transcript from exact project name, address fragment, or client name before decision="assign"

PROJECT JOURNAL CONTEXT (when available):
Some candidate projects may include journal state — recent claims, decisions,
commitments, and open loops extracted from prior calls. Use this context to inform
your reasoning:
- If the transcript discusses a topic matching an open loop or recent commitment
  for a project, that's corroborating evidence for attribution to that project
- If someone references a deadline or decision that appears in a project's journal,
  that strengthens the match
- Journal context is SUPPLEMENTARY — it does not replace transcript-grounded anchors
- A project with rich journal activity matching the conversation topic is more
  likely the correct attribution than one with no prior context

EMAIL CONTEXT (when available):
- Email context is WEAK corroboration only (subject keywords, mentions, amounts).
- Never auto-assign based only on email context.
- Use email context to break ties only when transcript-grounded anchors already exist.
- If email context conflicts with transcript anchors, trust the transcript.

GEO CONTEXT (when available):
- Geo signals are WEAK corroboration only (distance + role + place mentions).
- Never auto-assign based only on geo/proximity evidence.
- Destination/origin roles can increase confidence inside review band when transcript anchors already exist.
- If geo conflicts with strong transcript anchors, trust transcript anchors.

EVIDENCE BRIEF (from evidence-assembler):
For each candidate, you may see a structured assessment across 8 evidence
dimensions. Each dimension has a verdict: supports, contradicts, neutral,
or missing.

Interpretation rules:
- 3+ "supports" with 0 "contradicts" = STRONG candidate.
- Any "contradicts" requires explanation or use review.
- "missing" = signal unavailable, not evidence against.
- corroboration_count >= 3 enables the multi-source exception (0.65 threshold).
- alias_uniqueness "supports" + "alias_unique_single_project" = treat as exact_project_name anchor.
- chain_continuity "supports" with receipt from span_attributions = STRONG anchor.

CONFIDENCE THRESHOLDS (3-band policy):
- 0.75-1.00: Strong transcript-grounded evidence, safe to auto-assign
- 0.25-0.74: Some evidence exists, needs human review — ALWAYS include your best candidate project_id and reasoning
- 0.00-0.24: No meaningful evidence at all, truly no project match

MULTI-SOURCE CORROBORATION EXCEPTION:
When a candidate project's evidence includes 3 or more independent source categories
(e.g., transcript mention + affinity + journal claim + project_facts + geo),
a confidence of 0.65 or higher is sufficient for decision="assign".
This exception applies ONLY when the sources are genuinely independent — multiple
transcript matches from the same passage count as one source category.

ANCHOR STRENGTH POLICY:
To use decision="assign", you MUST have at least one STRONG anchor type:
- STRONG: exact_project_name, alias, address_fragment, client_name, chain_continuity
- WEAK: city_or_location, mentioned_contact, phonetic_or_pronunciation, continuity_callback, other

If your ONLY evidence is weak anchors (e.g., city name, zip code, county), you MUST use decision="review".
City/location matches alone are NEVER sufficient for auto-assign because multiple projects may share the same city.

CRITICAL GUARDRAIL:
To output decision="assign", you MUST provide at least one anchor with an EXACT QUOTE from the transcript in the "quote" field.
If you cannot find a direct quote supporting the attribution, you MUST use decision="review" or decision="none".

OUTPUT FORMAT (JSON only, no markdown):
{
  "project_id": "<uuid or null>",
  "confidence": <0.00-1.00>,
  "decision": "assign|review|none",
  "reasoning": "<1-3 sentences explaining the decision>",
  "anchors": [
    {
      "text": "<the matched term/phrase>",
      "candidate_project_id": "<uuid of the project this evidence supports>",
      "match_type": "<exact_project_name|alias|address_fragment|city_or_location|client_name|mentioned_contact|phonetic_or_pronunciation|continuity_callback|chain_continuity|other>",
      "quote": "<EXACT quote from transcript, max 50 chars>"
    }
  ],
  "journal_references": [
    {
      "project_id": "<uuid>",
      "claim_type": "<claim type from journal>",
      "claim_text": "<the journal claim that influenced your decision>",
      "relevance": "<how this claim relates to the transcript>"
    }
  ],
  "suggested_aliases": [
    {
      "project_id": "<uuid>",
      "alias_term": "<new alias to add>",
      "rationale": "<why this should be an alias>"
    }
  ]
}

IMPORTANT: The "quote" field in anchors must contain text that ACTUALLY APPEARS in the transcript segment provided.`;

function buildSystemPrompt(worldModelFactsEnabled: boolean): string {
  if (!worldModelFactsEnabled) return SYSTEM_PROMPT_BASE;
  return `${SYSTEM_PROMPT_BASE}

WORLD MODEL FACTS CONTEXT (when available):
- World model facts are supplementary corroboration, not primary evidence.
- Never assign a project using world model facts alone.
- World model facts may influence assignment only when:
  1) the cited facts include strong anchors (address/alias/client/rare-feature style evidence), and
  2) they do not contradict transcript evidence.
- If world model facts are weak-only or contradicted by transcript, choose decision="review" (or "none").

OUTPUT EXTENSION (when world model facts are present):
Add optional world_model_references array:
  "world_model_references": [
    {
      "project_id": "<uuid>",
      "fact_kind": "<fact_kind>",
      "fact_as_of_at": "<ISO timestamp or null>",
      "fact_excerpt": "<compact fact text used>",
      "relevance": "<how this fact supports your decision>"
    }
  ]`;
}

function buildUserPrompt(
  ctx: ContextPackage,
  opts: {
    worldModelFactsEnabled: boolean;
    projectFacts: ProjectFactsPack[];
  },
): string {
  const journalByProject = new Map<string, ProjectJournalState>();
  if (ctx.project_journal && Array.isArray(ctx.project_journal)) {
    for (const pj of ctx.project_journal) {
      journalByProject.set(pj.project_id, pj);
    }
  }

  const projectFacts = opts.worldModelFactsEnabled ? opts.projectFacts : [];

  const candidateList = ctx.candidates.map((c, i) => {
    const aliasMatchSummary = c.evidence.alias_matches.length > 0
      ? `Matches in transcript: ${c.evidence.alias_matches.map((m) => `"${m.term}" (${m.match_type})`).join(", ")}`
      : "No direct transcript matches";
    const commonAliases = c.aliases.filter((alias) => isCommonWordAlias(alias)).slice(0, 5);

    const geoSummary = c.evidence.geo_signal
      ? `Geo: distance=${
        typeof c.evidence.geo_distance_km === "number" ? `${c.evidence.geo_distance_km.toFixed(1)}km` : "n/a"
      }, score=${
        c.evidence.geo_signal.score.toFixed(2)
      }, role=${c.evidence.geo_signal.dominant_role}, places=${c.evidence.geo_signal.place_count}`
      : "Geo: none";

    const journalState = journalByProject.get(c.project_id);
    let journalSummary = "   - Journal: No prior context";
    if (journalState && (journalState.recent_claims.length > 0 || journalState.open_loops.length > 0)) {
      const claimsSummary = journalState.recent_claims.slice(0, 3).map(
        (cl) => `[${cl.claim_type}] ${cl.claim_text}`,
      ).join("; ");
      const loopsSummary = journalState.open_loops.map(
        (l) => `[${l.loop_type}] ${l.description}`,
      ).join("; ");
      journalSummary = `   - Journal (${journalState.active_claims_count} active claims):`;
      if (claimsSummary) journalSummary += `\n     Recent: ${claimsSummary}`;
      if (loopsSummary) journalSummary += `\n     Open loops: ${loopsSummary}`;
    }

    const worldModelSummary = opts.worldModelFactsEnabled
      ? buildWorldModelFactsCandidateSummary(c.project_id, projectFacts, 3)
      : null;

    // Evidence brief dimensions (from evidence-assembler, when present)
    const briefDims = (c as any).evidence_brief_dimensions;
    let briefSummary = "";
    if (briefDims && typeof briefDims === "object") {
      const dimLines = Object.entries(briefDims)
        .map(([dim, assessment]: [string, any]) => {
          if (!assessment || !assessment.verdict) return null;
          const rc = assessment.reason_code ? ` (${assessment.reason_code})` : "";
          return `     ${dim}: ${assessment.verdict}${rc}`;
        })
        .filter(Boolean);
      if (dimLines.length > 0) {
        const corr = (c as any).corroboration_count ?? "?";
        const contra = (c as any).contradiction_count ?? "?";
        briefSummary = `   - Evidence Brief [corr=${corr}, contra=${contra}]:\n${dimLines.join("\n")}`;
      }
    }

    return `${i + 1}. ${c.project_name}
   - ID: ${c.project_id}
   - Address: ${c.address || "N/A"}
   - Client: ${c.client_name || "N/A"}
   - Aliases: ${c.aliases.length > 0 ? c.aliases.slice(0, 5).join(", ") : "None"}
   - Common-word aliases (need corroboration): ${commonAliases.length > 0 ? commonAliases.join(", ") : "None"}
   - Status: ${c.status || "N/A"}, Phase: ${c.phase || "N/A"}
   - Evidence: assigned=${c.evidence.assigned}, affinity=${c.evidence.affinity_weight.toFixed(2)}, source_strength=${
      (c.evidence.source_strength ?? 0).toFixed(2)
    }, sources=[${c.evidence.sources.join(",")}]
   - ${geoSummary}
   - ${aliasMatchSummary}
${briefSummary ? `${briefSummary}\n` : ""}${journalSummary}${worldModelSummary ? `\n${worldModelSummary}` : ""}`;
  }).join("\n\n");

  const recentProjectList = ctx.contact.recent_projects.length > 0
    ? ctx.contact.recent_projects.map((p) => p.project_name).join(", ")
    : "None";

  const fanoutClass = ctx.contact.fanout_class || (ctx.contact.floater_flag ? "floater" : "unknown");
  const effectiveFanout = ctx.contact.effective_fanout ?? (ctx.contact.floater_flag ? 5 : 0);
  const fanoutSignal = fanoutClass === "anchored"
    ? "STRONG signal — contact works on only 1 project"
    : fanoutClass === "semi_anchored"
    ? "Moderate signal — contact works on 2 projects, needs corroboration"
    : fanoutClass === "drifter"
    ? "Weak signal — contact works on 3-4 projects, needs transcript grounding"
    : fanoutClass === "floater"
    ? "ANTI-signal — contact works on 5+ projects, treat like staff"
    : "No signal — no project association";

  const emailItems = Array.isArray(ctx.email_context) ? ctx.email_context.slice(0, 5) : [];
  const emailLookupMeta = ctx.email_lookup_meta || null;
  const emailLookupSummary = emailLookupMeta
    ? `returned=${Number(emailLookupMeta.returned_count || emailItems.length)}, cached=${
      emailLookupMeta.cached === true ? "yes" : "no"
    }, range=${emailLookupMeta.date_range || "unknown"}`
    : "not_run";
  const emailWarnings = emailLookupMeta?.warnings?.length ? emailLookupMeta.warnings.slice(0, 4).join(", ") : "none";
  const emailContextSummary = emailItems.length > 0
    ? emailItems.map((item, idx) => {
      const mentions = item.project_mentions?.length ? item.project_mentions.slice(0, 3).join(", ") : "none";
      const amounts = item.amounts_mentioned?.length ? item.amounts_mentioned.slice(0, 3).join(", ") : "none";
      const keywords = item.subject_keywords?.length ? item.subject_keywords.slice(0, 5).join(", ") : "none";
      const subject = (item.subject || "no subject").replace(/\s+/g, " ").slice(0, 120);
      const when = item.date || "unknown_date";
      return `${
        idx + 1
      }. ${when} | subject="${subject}" | mentions=[${mentions}] | amounts=[${amounts}] | keywords=[${keywords}]`;
    }).join("\n")
    : "No recent vendor email context";

  const placeMentions = Array.isArray(ctx.place_mentions) ? ctx.place_mentions.slice(0, 8) : [];
  const placeMentionSummary = placeMentions.length > 0
    ? placeMentions.map((p, idx) => {
      const roleTag = p.trigger_verb ? `${p.role} via "${p.trigger_verb}"` : `${p.role}`;
      const loc = (p.lat != null && p.lon != null) ? `${p.lat.toFixed(4)},${p.lon.toFixed(4)}` : "n/a";
      return `${idx + 1}. ${p.place_name} | role=${roleTag} | loc=${loc} | quote="${(p.snippet || "").slice(0, 90)}"`;
    }).join("\n")
    : "No explicit place mentions detected";

  return `TRANSCRIPT SEGMENT:
"""
${ctx.span.transcript_text}
"""

CALLER INFO:
- Name: ${ctx.contact.contact_name || "Unknown"}
- Fanout: ${effectiveFanout} projects (${fanoutClass})
- Signal strength: ${fanoutSignal}
- Recent Projects: ${recentProjectList}

EMAIL CONTEXT (WEAK CORROBORATION):
- Lookup: ${emailLookupSummary}
- Warnings: ${emailWarnings}
${emailContextSummary}

GEO PLACE MENTIONS (WEAK CORROBORATION):
${placeMentionSummary}

CANDIDATE PROJECTS (${ctx.candidates.length} total):
${candidateList || "No candidates found"}

Analyze the transcript and determine which project (if any) this conversation is about.
Consider the contact's fanout class — an anchored contact (fanout=1) on a single project is strong evidence; a floater (fanout>=5) provides no identity signal.
Consider the journal context for each project — if the conversation topic matches known commitments, decisions, or open loops for a project, that strengthens the attribution.
  Treat email context as weak corroboration only; never use email context alone for decision="assign".
  Treat geo context as weak corroboration only; use it as a tie-breaker when transcript evidence is otherwise close.
  If journal claims influenced your decision, include them in journal_references.
  ${
    opts.worldModelFactsEnabled
      ? "If world model facts influenced your decision, include them in world_model_references."
      : ""
  }
  Remember: You MUST include an exact quote from the transcript to use decision="assign".`;
}

// ============================================================
// MAIN HANDLER
// ============================================================

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const edgeSecretHeader = req.headers.get("X-Edge-Secret");
  const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
  if (!expectedSecret || edgeSecretHeader !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  let context_package: ContextPackage | null = body.context_package || null;
  const dry_run = body.dry_run === true;

  if (!context_package) {
    return new Response(JSON.stringify({ error: "missing_context_package" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const span_id = context_package.meta?.span_id;
  if (!span_id) {
    return new Response(JSON.stringify({ error: "missing_span_id_in_context_package" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── CLOSED-PROJECT HARD FILTER (pre-inference) ─────────────
  // Defense-in-depth: remove candidates with ineligible project status
  // before they reach the LLM. Context-assembly already filters at the
  // DB level, but this catches leaks from direct calls or stale data.
  const closedProjectFilter = filterClosedProjectCandidates(context_package);
  context_package = closedProjectFilter.filtered;
  if (closedProjectFilter.removed_count > 0) {
    console.log(
      `[ai-router] Closed-project hard filter removed ${closedProjectFilter.removed_count} candidates pre-inference`,
    );
  }

  const homeownerOverrideEvaluation = evaluateHomeownerOverride(
    context_package.meta,
    (context_package.candidates || []).map((candidate) => candidate.project_id),
  );
  const homeownerOverrideStrongAnchor = homeownerOverrideEvaluation.strong_anchor_active;
  const homeownerOverrideProjectId = homeownerOverrideEvaluation.deterministic_project_id || "";
  const homeownerOverrideSkipReason = homeownerOverrideEvaluation.skip_reason;

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let result: AttributionResult;
  let raw_response: any = null;
  let tokens_used = 0;
  let inference_ms = 0;
  let model_error = false;
  let common_alias_unconfirmed = false;
  let common_alias_terms: string[] = [];
  let bizdev_call_type: "bizdev_prospect_intake" | "project_execution" = "project_execution";
  let bizdev_confidence: "high" | "medium" | "low" = "low";
  let bizdev_evidence_tags: string[] = [];
  let bizdev_commitment_to_start = false;
  let bizdev_commitment_tags: string[] = [];
  let bizdev_without_commitment = false;
  let world_model_references: WorldModelReference[] = [];
  let worldModelGuardrailDowngraded = false;
  let worldModelGuardrailReason: string | null = null;
  let worldModelStrongAnchorPresent = false;
  let worldModelContradictionFound = false;
  let strictSanitizationRetryUsed = false;
  let transcriptControlCharsSanitized = 0;
  let homeownerDeterministicGateApplied = false;
  let homeownerDeterministicFallbackApplied = false;
  let junkCallFiltered = false;
  let junkCallFilterReasonCodes: string[] = [];
  let junkCallFilterSignalSummary: string[] = [];
  let matchedTermsForWrite: string[] = [];
  let matchPositionsForWrite: ProvenancePointer[] = [];
  let stoplineDowngradeReason: "insufficient_provenance_pointer_quality" | "doc_anchor_missing" | null = null;
  let stoplineTranscriptAnchorCount = 0;
  let stoplineDocProvenanceCount = 0;

  const currentEvidenceEventIds = Array.from(
    new Set(
      [
        ...(Array.isArray(context_package.meta?.current_evidence_event_ids)
          ? context_package.meta.current_evidence_event_ids
          : []),
        ...(Array.isArray(context_package.meta?.evidence_event_ids) ? context_package.meta.evidence_event_ids : []),
      ].map((id: unknown) => String(id || "").trim()).filter(Boolean),
    ),
  );
  const projectFactsForPrompt = WORLD_MODEL_FACTS_ENABLED
    ? filterProjectFactsForPrompt(context_package.project_facts, {
      interaction_id: context_package.meta?.interaction_id || "",
      current_evidence_event_ids: currentEvidenceEventIds,
      max_per_project: WORLD_MODEL_FACTS_MAX_PER_PROJECT,
    })
    : [];

  try {
    const anthropic = new Anthropic({
      apiKey: Deno.env.get("ANTHROPIC_API_KEY")!,
    });

    const runInference = async (contextPackageForPrompt: ContextPackage) => {
      const inferenceStart = Date.now();
      const response = await anthropic.messages.create({
        model: MODEL_ID,
        max_tokens: MAX_TOKENS,
        messages: [
          {
            role: "user",
            content: buildUserPrompt(contextPackageForPrompt, {
              worldModelFactsEnabled: WORLD_MODEL_FACTS_ENABLED,
              projectFacts: projectFactsForPrompt,
            }),
          },
        ],
        system: buildSystemPrompt(WORLD_MODEL_FACTS_ENABLED),
      });
      const inferenceElapsedMs = Date.now() - inferenceStart;
      const tokensUsed = (response.usage?.input_tokens || 0) + (response.usage?.output_tokens || 0);
      const textBlock = response.content.find((b: any) => b.type === "text");
      const responseText = textBlock?.type === "text" ? textBlock.text : "";
      const parsed = parseLlmJson<any>(responseText).value;

      return {
        parsed,
        response,
        inferenceElapsedMs,
        tokensUsed,
        transcriptText: contextPackageForPrompt.span?.transcript_text || "",
      };
    };

    const defaultContext = withSanitizedTranscript(context_package, "default");
    transcriptControlCharsSanitized = defaultContext.replaced;

    let inferenceResult: {
      parsed: any;
      response: any;
      inferenceElapsedMs: number;
      tokensUsed: number;
      transcriptText: string;
    };

    try {
      inferenceResult = await runInference(defaultContext.context);
    } catch (primaryError: any) {
      strictSanitizationRetryUsed = true;
      console.warn(
        `[ai-router] Retrying inference with strict transcript sanitization: ${
          primaryError?.message || "unknown_error"
        }`,
      );
      const strictContext = withSanitizedTranscript(context_package, "strict");
      transcriptControlCharsSanitized = Math.max(transcriptControlCharsSanitized, strictContext.replaced);
      inferenceResult = await runInference(strictContext.context);
    }

    inference_ms = inferenceResult.inferenceElapsedMs;
    tokens_used = inferenceResult.tokensUsed;
    raw_response = inferenceResult.response;
    const parsed = inferenceResult.parsed;

    let project_id = parsed.project_id || null;
    let confidence = Math.max(0, Math.min(1, Number(parsed.confidence) || 0));
    const anchors: Anchor[] = Array.isArray(parsed.anchors) ? parsed.anchors : [];
    const suggested_aliases: SuggestedAlias[] = Array.isArray(parsed.suggested_aliases) ? parsed.suggested_aliases : [];
    const journal_references: JournalReference[] = Array.isArray(parsed.journal_references)
      ? parsed.journal_references
      : [];
    world_model_references = WORLD_MODEL_FACTS_ENABLED ? parseWorldModelReferences(parsed.world_model_references) : [];

    let decision = parsed.decision as "assign" | "review" | "none";
    let reasoning = parsed.reasoning || "No reasoning provided";
    const spanTranscript = inferenceResult.transcriptText;
    const { valid: hasValidAnchor, validatedAnchors, rejectedStaffAnchors } = validateAnchorQuotes(
      anchors,
      spanTranscript,
    );

    if (rejectedStaffAnchors > 0) {
      console.log(
        `[ai-router] Rejected ${rejectedStaffAnchors} staff-name anchors, ${validatedAnchors.length} valid anchors remain`,
      );
    }

    if (decision === "assign" && !hasValidAnchor) {
      decision = "review";
      console.log(
        `[ai-router] Downgraded to review: no valid anchors after filtering (staff anchors rejected: ${rejectedStaffAnchors})`,
      );
    }

    if (decision === "assign" && !hasStrongAnchor(validatedAnchors) && !homeownerOverrideStrongAnchor) {
      decision = "review";
      console.log(
        `[ai-router] Downgraded to review: only weak anchors (city/location), no strong anchor (project name, address, client)`,
      );
    } else if (decision === "assign" && !hasStrongAnchor(validatedAnchors) && homeownerOverrideStrongAnchor) {
      console.log(
        "[ai-router] Homeowner override active: preserving assign despite weak anchor set",
      );
    }

    const aliasGuardrail = applyCommonAliasCorroborationGuardrail({
      decision,
      project_id,
      anchors: validatedAnchors,
    });
    decision = aliasGuardrail.decision;
    common_alias_unconfirmed = aliasGuardrail.common_alias_unconfirmed;
    common_alias_terms = aliasGuardrail.flagged_alias_terms;
    if (aliasGuardrail.downgraded) {
      console.log(
        `[ai-router] Downgraded to review: common-word alias lacked corroboration for project ${project_id} (aliases=${
          common_alias_terms.join(",") || "unknown"
        })`,
      );
    }

    const bethanyGuardrail = applyBethanyRoadWinshipGuardrail({
      decision,
      project_id,
      confidence,
      reasoning,
      anchors: validatedAnchors,
      candidates: context_package.candidates,
    });
    decision = bethanyGuardrail.decision;
    project_id = bethanyGuardrail.project_id;
    confidence = bethanyGuardrail.confidence;
    reasoning = bethanyGuardrail.reasoning;
    if (bethanyGuardrail.applied) {
      console.log(
        `[ai-router] Bethany guardrail forced assignment to Winship candidate ${bethanyGuardrail.chosen_project_id}`,
      );
    }

    if (decision === "assign" && confidence < THRESHOLD_AUTO_ASSIGN) {
      decision = "review";
    }
    if (confidence < THRESHOLD_REVIEW) {
      decision = "none";
    }

    // v1.15.0: Safe low-confidence assign — promote review→assign when guardrails are satisfied
    if (decision === "review" && project_id) {
      const fanoutClass = context_package.contact?.fanout_class ||
        (context_package.contact?.floater_flag ? "floater" : "unknown");
      const safeLowAssign = evaluateSafeLowConfidenceAssign({
        decision,
        project_id,
        confidence,
        fanout_class: fanoutClass,
        candidates: context_package.candidates || [],
      });
      if (safeLowAssign.promoted) {
        decision = "assign";
        confidence = Math.max(confidence, THRESHOLD_AUTO_ASSIGN);
        reasoning = `${reasoning} safe_low_confidence_assign: ${safeLowAssign.reason}.`;
        console.log(
          `[ai-router] Safe low-confidence assign promoted review→assign: project=${project_id} reason=${safeLowAssign.reason}`,
        );
      }
    }

    const bizdevGate = applyBizDevCommitmentGate({
      transcript: spanTranscript,
      decision,
      project_id,
    });
    decision = bizdevGate.decision;
    project_id = bizdevGate.project_id;
    bizdev_call_type = bizdevGate.classification.call_type;
    bizdev_confidence = bizdevGate.classification.confidence;
    bizdev_evidence_tags = bizdevGate.classification.evidence_tags;
    bizdev_commitment_to_start = bizdevGate.classification.commitment_to_start;
    bizdev_commitment_tags = bizdevGate.classification.commitment_tags;
    bizdev_without_commitment = bizdevGate.reason === "bizdev_without_commitment";

    if (bizdev_without_commitment) {
      const signalSummary = bizdev_evidence_tags.slice(0, 4).join(", ");
      const commitmentSummary = bizdev_commitment_tags.slice(0, 4).join(", ");
      reasoning = `${reasoning} BizDev prospect gate held project assignment (${
        signalSummary || "prospect signals detected"
      }; commitment_terms=${commitmentSummary || "none"}).`;
      console.log(
        `[ai-router] BizDev commitment gate active: project assignment withheld (signals=${signalSummary || "none"})`,
      );
    }

    if (WORLD_MODEL_FACTS_ENABLED && world_model_references.length > 0) {
      const worldModelGuardrail = applyWorldModelReferenceGuardrail({
        decision,
        project_id,
        transcript: spanTranscript,
        world_model_references,
        project_facts: projectFactsForPrompt,
      });
      world_model_references = worldModelGuardrail.world_model_references;
      worldModelGuardrailDowngraded = worldModelGuardrail.downgraded;
      worldModelGuardrailReason = worldModelGuardrail.reason_code;
      worldModelStrongAnchorPresent = worldModelGuardrail.strong_anchor_present;
      worldModelContradictionFound = worldModelGuardrail.contradiction_found;
      if (worldModelGuardrail.decision !== decision) {
        decision = worldModelGuardrail.decision;
      }
      if (worldModelGuardrail.downgraded) {
        reasoning = `${reasoning} world_model_guardrail:${worldModelGuardrail.reason_code || "downgraded_to_review"}.`;
        console.log(
          `[ai-router] World-model guardrail downgraded assignment: reason=${
            worldModelGuardrail.reason_code || "unknown"
          }`,
        );
      }
    }

    if (homeownerOverrideStrongAnchor && homeownerOverrideProjectId.length > 0) {
      const shouldForceHomeownerAssign = decision !== "assign" ||
        project_id !== homeownerOverrideProjectId ||
        confidence < THRESHOLD_AUTO_ASSIGN;

      if (shouldForceHomeownerAssign) {
        const previousDecision = decision;
        const previousProject = project_id;
        homeownerDeterministicGateApplied = true;
        decision = "assign";
        project_id = homeownerOverrideProjectId;
        confidence = Math.max(confidence, THRESHOLD_AUTO_ASSIGN, 0.92);
        reasoning =
          `${reasoning} deterministic_homeowner_override_gate: forced assign to homeowner project ${homeownerOverrideProjectId} (prev_decision=${previousDecision}, prev_project=${
            previousProject || "null"
          }).`;
        console.log(
          `[ai-router] Deterministic homeowner gate forced assignment: project=${homeownerOverrideProjectId} prev_decision=${previousDecision} prev_project=${
            previousProject || "null"
          }`,
        );
      }
    } else if (homeownerOverrideSkipReason === "multi_project_span") {
      console.log("[ai-router] Homeowner deterministic gate skipped: multi-project span detected");
    }

    result = {
      span_id,
      project_id,
      confidence,
      decision,
      reasoning,
      anchors: validatedAnchors,
      suggested_aliases: suggested_aliases.length > 0 ? suggested_aliases : undefined,
      journal_references: journal_references.length > 0 ? journal_references : undefined,
      world_model_references: world_model_references.length > 0 ? world_model_references : undefined,
    };
  } catch (e: any) {
    const errorText = String(e?.message || "unknown_error").replace(/\s+/g, " ").slice(0, 220);
    console.error("AI Router inference error:", errorText);

    if (homeownerOverrideStrongAnchor && homeownerOverrideProjectId.length > 0) {
      homeownerDeterministicFallbackApplied = true;
      model_error = false;
      result = {
        span_id,
        project_id: homeownerOverrideProjectId,
        confidence: 0.92,
        decision: "assign",
        reasoning: `deterministic_homeowner_fallback_after_model_error: ${errorText}`,
        anchors: [],
      };
    } else {
      model_error = true;
      result = {
        span_id,
        project_id: null,
        confidence: 0,
        decision: "review",
        reasoning: `model_error: ${errorText}`,
        anchors: [],
      };
    }
  }
  const homeownerDeterministicAssignApplied = homeownerDeterministicGateApplied ||
    homeownerDeterministicFallbackApplied;

  // ========================================
  // STOPLINE: NO UNANCHORED ASSIGNMENTS
  // ========================================
  const pointerTranscriptMode: TranscriptSanitizeMode = strictSanitizationRetryUsed ? "strict" : "default";
  const pointerTranscript =
    withSanitizedTranscript(context_package, pointerTranscriptMode).context.span?.transcript_text ||
    "";
  const spanCharStartRaw = Number(context_package.span?.char_start);
  const spanCharEndRaw = Number(context_package.span?.char_end);
  const spanCharStart = Number.isFinite(spanCharStartRaw) ? spanCharStartRaw : null;
  const spanCharEnd = Number.isFinite(spanCharEndRaw) ? spanCharEndRaw : null;

  const transcriptPointers = buildTranscriptAnchorPointers(
    result.anchors || [],
    pointerTranscript,
    spanCharStart,
    spanCharEnd,
  );
  const docProvenancePointers = buildProjectFactProvenancePointers(
    result.project_id,
    result.world_model_references || world_model_references,
    projectFactsForPrompt,
  );
  stoplineTranscriptAnchorCount = transcriptPointers.length;
  stoplineDocProvenanceCount = docProvenancePointers.length;
  matchPositionsForWrite = [...transcriptPointers, ...docProvenancePointers];
  matchedTermsForWrite = uniqueStrings(matchPositionsForWrite.map((p) => p.term)).slice(0, 32);

  const hasStoplineAnchorEvidence = stoplineTranscriptAnchorCount > 0 || stoplineDocProvenanceCount > 0;
  if (!model_error && result.decision === "assign" && result.project_id && !hasStoplineAnchorEvidence) {
    stoplineDowngradeReason = (result.anchors?.length || 0) > 0
      ? "doc_anchor_missing"
      : "insufficient_provenance_pointer_quality";
    result = {
      ...result,
      decision: "review",
      reasoning: `${result.reasoning} stopline_no_unanchored_assignments:${stoplineDowngradeReason}.`,
    };
    console.log(
      `[ai-router] Stopline downgrade assign→review: span=${span_id} reason=${stoplineDowngradeReason}`,
    );
  }

  // ========================================
  // BLOCKLIST ENFORCEMENT (belt-and-suspenders)
  // ========================================
  if (result.project_id) {
    const { data: blockRow } = await db
      .from("project_attribution_blocklist")
      .select("block_mode, reason")
      .eq("project_id", result.project_id)
      .eq("active", true)
      .eq("block_mode", "hard_block")
      .maybeSingle();

    if (blockRow) {
      console.log(`[ai-router] BLOCKLIST HIT: project_id=${result.project_id} blocked (${blockRow.reason})`);
      result = {
        ...result,
        project_id: null,
        confidence: 0,
        decision: "none",
        reasoning: `blocked_project: ${blockRow.reason}. Original decision overridden by blocklist.`,
      };
    }
  }

  // ========================================
  // CLOSED-PROJECT HARD FILTER (post-inference)
  // ========================================
  // Defense-in-depth: verify the chosen project is still eligible after
  // inference. Catches cases where the LLM picks a project_id that wasn't
  // in the candidate list, or where project status changed between
  // context-assembly and ai-router execution.
  if (result.project_id && result.decision === "assign") {
    const { data: chosenProject } = await db
      .from("projects")
      .select("status")
      .eq("id", result.project_id)
      .maybeSingle();

    const chosenStatus = String(chosenProject?.status || "").trim().toLowerCase();
    if (chosenProject && !ATTRIBUTION_ELIGIBLE_STATUSES.has(chosenStatus)) {
      console.log(
        `[ai-router] Closed-project hard filter (post-inference): project_id=${result.project_id} status=${chosenStatus} → downgraded to review`,
      );
      result = {
        ...result,
        decision: "review",
        reasoning:
          `${result.reasoning} closed_project_hard_filter: chosen project status=${chosenStatus} is not attribution-eligible.`,
      };
    }
  }

  const junkPrefilter = evaluateJunkCallPrefilter({
    transcript: context_package.span?.transcript_text || "",
    durationSeconds: deriveSpanDurationSeconds(context_package),
  });
  junkCallFilterReasonCodes = junkPrefilter.reasonCodes;
  junkCallFilterSignalSummary = junkPrefilter.signalSummary;

  if (
    !homeownerDeterministicAssignApplied &&
    !model_error &&
    result.decision !== "assign" &&
    junkPrefilter.isJunk
  ) {
    junkCallFiltered = true;
    result = {
      ...result,
      project_id: null,
      confidence: Math.min(result.confidence || 0, 0.2),
      decision: "none",
      reasoning: `${result.reasoning} junk_call_filtered: ${junkPrefilter.reasonCodes.join(",")} (${
        junkPrefilter.signalSummary.join(",")
      })`,
    };
    console.log(
      `[ai-router] junk-call prefilter applied: span=${span_id} reasons=${junkPrefilter.reasonCodes.join(",")}`,
    );
  }

  // ========================================
  // GATEKEEPER (SPAN-LEVEL ONLY)
  // ========================================
  let applied = false;
  let applied_project_id: string | null = null;
  let gatekeeper_reason: string | null = null;
  let journal_extract_fired = false;

  if (!dry_run) {
    const { data: existingAttribution } = await db
      .from("span_attributions")
      .select("attribution_lock, applied_project_id, project_id, applied_at_utc")
      .eq("span_id", span_id)
      .maybeSingle();

    const currentLock = existingAttribution?.attribution_lock ?? null;
    const preservedAppliedProjectId = existingAttribution?.applied_project_id ?? existingAttribution?.project_id ??
      null;
    const preservedAppliedAtUtc = existingAttribution?.applied_at_utc ?? null;

    const wouldApply = result.decision === "assign" && result.confidence >= THRESHOLD_AUTO_ASSIGN;
    const newLock = wouldApply ? "ai" : null;
    const lockCanOverwrite = canOverwriteLock(currentLock, newLock);

    if (!lockCanOverwrite) {
      gatekeeper_reason = currentLock === "human" ? "human_lock_present" : "ai_lock_preserved";
      applied = false;
      applied_project_id = preservedAppliedProjectId;
      console.log(`[ai-router] Lock preserved: current=${currentLock}, attempted=${newLock}`);
    } else {
      const spanTranscript = withSanitizedTranscript(context_package, "default").context.span?.transcript_text || "";
      const { valid: hasValidAnchor } = validateAnchorQuotes(result.anchors, spanTranscript);
      const allowDeterministicHomeownerAssign = homeownerDeterministicAssignApplied && homeownerOverrideStrongAnchor;
      const hasStoplineProvenanceForApply = stoplineTranscriptAnchorCount > 0 || stoplineDocProvenanceCount > 0;

      if (
        result.decision === "assign" &&
        result.confidence >= THRESHOLD_AUTO_ASSIGN &&
        ((hasValidAnchor && hasStoplineProvenanceForApply) || allowDeterministicHomeownerAssign)
      ) {
        applied = true;
        applied_project_id = result.project_id;
        gatekeeper_reason = "auto_assigned";
      } else if (
        result.decision === "review" ||
        (result.confidence >= THRESHOLD_REVIEW && result.confidence < THRESHOLD_AUTO_ASSIGN)
      ) {
        applied = false;
        applied_project_id = null;
        gatekeeper_reason = "needs_review";
      } else {
        applied = false;
        applied_project_id = null;
        gatekeeper_reason = "no_match";
      }
    }

    // ========================================
    // WRITE TO SPAN_ATTRIBUTIONS (ALWAYS)
    // ========================================
    const attribution_lock = !lockCanOverwrite ? currentLock : (applied ? "ai" : null);
    const needs_review = junkCallFiltered ? false : result.decision === "review" || result.decision === "none";
    const attribution_source = junkCallFiltered
      ? "junk_call_prefilter"
      : homeownerDeterministicFallbackApplied
      ? "homeowner_deterministic_fallback"
      : homeownerDeterministicGateApplied
      ? "homeowner_deterministic_override"
      : deriveAttributionSource(result.anchors, model_error);
    const evidence_tier = junkCallFiltered
      ? 3
      : homeownerDeterministicAssignApplied
      ? 1
      : deriveEvidenceTier(result.anchors, result.confidence, model_error);

    const { error: upsertErr } = await db.from("span_attributions").upsert({
      span_id,
      project_id: result.project_id,
      confidence: result.confidence,
      decision: result.decision,
      reasoning: result.reasoning,
      anchors: result.anchors,
      matched_terms: matchedTermsForWrite,
      match_positions: matchPositionsForWrite,
      journal_references: result.journal_references || [],
      suggested_aliases: result.suggested_aliases || [],
      prompt_version: PROMPT_VERSION,
      model_id: MODEL_ID,
      raw_response,
      tokens_used,
      inference_ms,
      attribution_lock,
      applied_project_id,
      applied_at_utc: !lockCanOverwrite ? preservedAppliedAtUtc : (applied ? new Date().toISOString() : null),
      needs_review,
      attribution_source,
      evidence_tier,
      attributed_by: `ai-router-${FUNCTION_VERSION}`,
      attributed_at: new Date().toISOString(),
    }, {
      onConflict: "span_id,model_id,prompt_version",
      ignoreDuplicates: false,
    });

    if (upsertErr) {
      console.error("[ai-router] span_attributions upsert failed:", upsertErr.message, upsertErr.details);
      const interaction_id = context_package.meta?.interaction_id;
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "attribution_write_failed",
          error: upsertErr.message,
          interaction_id,
          span_id,
        }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // ========================================
    // REVIEW QUEUE WIRING (PR-4)
    // ========================================
    const interaction_id = context_package.meta?.interaction_id;
    const quoteVerified = stoplineTranscriptAnchorCount > 0;
    const quoteRequirementSatisfied = quoteVerified || stoplineDocProvenanceCount > 0 ||
      homeownerDeterministicAssignApplied;
    const strongAnchorPresent = hasStrongAnchor(result.anchors);
    const effectiveStrongAnchor = strongAnchorPresent || homeownerOverrideStrongAnchor ||
      homeownerDeterministicAssignApplied || stoplineDocProvenanceCount > 0;
    const bizdevGateEffective = bizdev_without_commitment && !homeownerDeterministicAssignApplied;
    const bizdevSuppressedByHomeownerDeterministic = bizdev_without_commitment && homeownerDeterministicAssignApplied;

    const needsReviewQueue = !junkCallFiltered &&
      (
        result.decision !== "assign" ||
        needs_review === true ||
        !quoteRequirementSatisfied ||
        !effectiveStrongAnchor ||
        common_alias_unconfirmed ||
        bizdevGateEffective ||
        (model_error && !homeownerDeterministicAssignApplied)
      );

    if (needsReviewQueue) {
      const reason_codes = buildReasonCodes({
        modelReasons: null,
        quoteVerified: quoteRequirementSatisfied,
        strongAnchor: effectiveStrongAnchor,
        modelError: model_error && !homeownerDeterministicAssignApplied,
        ambiguousContact: (context_package.contact?.fanout_class === "floater" ||
          context_package.contact?.fanout_class === "drifter") || (context_package.contact?.floater_flag === true),
        geoOnly: !effectiveStrongAnchor && result.anchors.some((a) => a.match_type === "city_or_location"),
        commonAliasUnconfirmed: common_alias_unconfirmed,
        bizdevWithoutCommitment: bizdevGateEffective,
        stoplineReason: stoplineDowngradeReason,
      });

      const context_payload = {
        span_id,
        interaction_id,
        candidate_project_id: result.project_id,
        candidate_confidence: result.confidence,
        transcript_snippet: sanitizeTranscriptText(context_package.span?.transcript_text || "", "default").text
          .slice(0, 600),
        candidates: context_package.candidates?.map((c) => ({
          project_id: c.project_id,
          name: c.project_name,
          evidence_tags: c.evidence?.sources || [],
        })) || [],
        anchors: result.anchors,
        provenance: {
          transcript_anchor_count: stoplineTranscriptAnchorCount,
          doc_provenance_count: stoplineDocProvenanceCount,
          matched_terms: matchedTermsForWrite,
          match_positions: matchPositionsForWrite,
          stopline_downgrade_reason: stoplineDowngradeReason,
        },
        ...(WORLD_MODEL_FACTS_ENABLED
          ? {
            world_model_references: result.world_model_references || [],
            world_model_guardrail: {
              enabled: WORLD_MODEL_FACTS_ENABLED,
              downgraded: worldModelGuardrailDowngraded,
              reason: worldModelGuardrailReason,
              strong_anchor_present: worldModelStrongAnchorPresent,
              contradiction_found: worldModelContradictionFound,
              project_facts_available: projectFactsForPrompt.some((pack) => pack.facts.length > 0),
            },
          }
          : {}),
        alias_guardrails: {
          common_alias_unconfirmed,
          flagged_alias_terms: common_alias_terms,
        },
        bizdev_classifier: {
          call_type: bizdev_call_type,
          confidence: bizdev_confidence,
          evidence_tags: bizdev_evidence_tags,
          commitment_to_start: bizdev_commitment_to_start,
          commitment_tags: bizdev_commitment_tags,
          gate_active: bizdevGateEffective,
          gate_suppressed_by_homeowner_override: bizdevSuppressedByHomeownerDeterministic,
        },
        homeowner_override: {
          active: homeownerOverrideStrongAnchor,
          project_id: context_package.meta?.homeowner_override_project_id || null,
          conflict_project_id: context_package.meta?.homeowner_override_conflict_project_id || null,
          conflict_term: context_package.meta?.homeowner_override_conflict_term || null,
          skip_reason: homeownerOverrideSkipReason,
          deterministic_gate_applied: homeownerDeterministicGateApplied,
          deterministic_fallback_applied: homeownerDeterministicFallbackApplied,
        },
        homeowner_deterministic_gate: homeownerDeterministicGateApplied,
        homeowner_deterministic_fallback: homeownerDeterministicFallbackApplied,
        sanitization: {
          control_chars_sanitized: transcriptControlCharsSanitized,
          strict_retry_used: strictSanitizationRetryUsed,
        },
        junk_prefilter: {
          applied: junkCallFiltered,
          reason_codes: junkCallFilterReasonCodes,
          signal_summary: junkCallFilterSignalSummary,
        },
        model_id: MODEL_ID,
        prompt_version: PROMPT_VERSION,
        created_at_utc: new Date().toISOString(),
      };

      const reviewQueueResult = await upsertReviewQueue(db, {
        span_id,
        interaction_id: interaction_id || span_id,
        reasons: reason_codes,
        context_payload,
      });
      if (reviewQueueResult.error) {
        return new Response(
          JSON.stringify({
            ok: false,
            error_code: "review_queue_write_failed",
            error: reviewQueueResult.error.message,
            interaction_id,
            span_id,
          }),
          {
            status: 500,
            headers: { "Content-Type": "application/json" },
          },
        );
      }
      console.log(`[ai-router] Created review_queue item for span ${span_id}, reasons: ${reason_codes.join(",")}`);
    } else {
      const resolutionNotes = junkCallFiltered ? "junk_call_filtered" : "auto-applied by ai-router";
      const resolveResult = await resolveReviewQueue(db, span_id, resolutionNotes);
      if (resolveResult.error) {
        return new Response(
          JSON.stringify({
            ok: false,
            error_code: "review_queue_resolve_failed",
            error: resolveResult.error.message,
            interaction_id,
            span_id,
          }),
          {
            status: 500,
            headers: { "Content-Type": "application/json" },
          },
        );
      }
      console.log(`[ai-router] Resolved review_queue item for span ${span_id} (${resolutionNotes})`);
    }

    // ========================================
    // v1.8.1: CHAIN TO JOURNAL-EXTRACT (fire-and-forget)
    // Fires after attribution lands so journal-extract can read
    // applied_project_id from span_attributions.
    // Belt-and-suspenders with segment-call hook — ensures journal
    // extraction runs even for backfill/replay/manual invocations.
    // journal-extract has its own idempotency guard (skips if claims
    // already exist for this span_id) and handles null project_id
    // gracefully (skips DB insert, returns reason).
    // ========================================
    if (!model_error && span_id) {
      const edgeSecretVal = Deno.env.get("EDGE_SHARED_SECRET");
      const journalExtractUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/journal-extract`;
      if (edgeSecretVal) {
        try {
          const jeResp = await fetch(journalExtractUrl, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Edge-Secret": edgeSecretVal,
            },
            body: JSON.stringify({
              span_id,
              interaction_id: context_package.meta?.interaction_id,
            }),
          });
          journal_extract_fired = true;
          if (!jeResp.ok) {
            const errBody = await jeResp.text().catch(() => "unknown");
            console.warn(`[ai-router] journal-extract chain ${jeResp.status}: ${errBody.slice(0, 200)}`);
          } else {
            const jeData = await jeResp.json().catch(() => null);
            console.log(
              `[ai-router] journal-extract chain OK: claims_extracted=${
                jeData?.claims_extracted ?? "?"
              }, claims_written=${jeData?.claims_written ?? "?"}`,
            );
          }
        } catch (e: any) {
          console.warn(`[ai-router] journal-extract chain error: ${e.message}`);
        }
      }
    }
  }

  // ========================================
  // RESPONSE
  // ========================================
  return new Response(
    JSON.stringify({
      ok: true,
      span_id,
      project_id: result.project_id,
      confidence: result.confidence,
      decision: result.decision,
      reasoning: result.reasoning,
      anchors: result.anchors,
      journal_references: result.journal_references,
      ...(WORLD_MODEL_FACTS_ENABLED
        ? {
          world_model_references: result.world_model_references || [],
        }
        : {}),
      suggested_aliases: result.suggested_aliases,
      gatekeeper: {
        applied,
        applied_project_id,
        reason: gatekeeper_reason,
      },
      guardrails: {
        common_alias_unconfirmed,
        flagged_alias_terms: common_alias_terms,
        homeowner_deterministic_gate_applied: homeownerDeterministicGateApplied,
        homeowner_deterministic_fallback_applied: homeownerDeterministicFallbackApplied,
        homeowner_override_skip_reason: homeownerOverrideSkipReason,
        ...(WORLD_MODEL_FACTS_ENABLED
          ? {
            world_model: {
              enabled: WORLD_MODEL_FACTS_ENABLED,
              references_count: world_model_references.length,
              downgraded: worldModelGuardrailDowngraded,
              reason: worldModelGuardrailReason,
              strong_anchor_present: worldModelStrongAnchorPresent,
              contradiction_found: worldModelContradictionFound,
              project_facts_available: projectFactsForPrompt.some((pack) => pack.facts.length > 0),
            },
          }
          : {}),
        junk_call_prefilter: {
          applied: junkCallFiltered,
          reason_codes: junkCallFilterReasonCodes,
          signal_summary: junkCallFilterSignalSummary,
        },
        sanitization: {
          control_chars_sanitized: transcriptControlCharsSanitized,
          strict_retry_used: strictSanitizationRetryUsed,
        },
        bizdev_classifier: {
          call_type: bizdev_call_type,
          confidence: bizdev_confidence,
          evidence_tags: bizdev_evidence_tags,
          commitment_to_start: bizdev_commitment_to_start,
          commitment_tags: bizdev_commitment_tags,
          gate_active: bizdev_without_commitment && !homeownerDeterministicAssignApplied,
          gate_suppressed_by_homeowner_override: bizdev_without_commitment && homeownerDeterministicAssignApplied,
        },
        stopline_no_unanchored_assignments: {
          transcript_anchor_count: stoplineTranscriptAnchorCount,
          doc_provenance_count: stoplineDocProvenanceCount,
          matched_terms_count: matchedTermsForWrite.length,
          downgraded: stoplineDowngradeReason !== null,
          reason: stoplineDowngradeReason,
        },
      },
      post_hooks: {
        journal_extract_fired,
      },
      model_error,
      dry_run,
      model_id: MODEL_ID,
      prompt_version: PROMPT_VERSION,
      function_version: FUNCTION_VERSION,
      tokens_used,
      inference_ms,
      ms: Date.now() - t0,
    }),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
