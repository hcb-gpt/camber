/**
 * audit-attribution-reviewer Edge Function v0.1.0
 *
 * Packet-only reviewer:
 * - Accepts `packet_json` payload
 * - Produces reviewer verdict JSON
 * - Does NOT query DB or fetch external context beyond provided packet
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { parseLlmJson } from "../_shared/llm_json.ts";

const FUNCTION_SLUG = "audit-attribution-reviewer";
const FUNCTION_VERSION = "v0.1.1";
const SAFE_FALLBACK_MODEL_ID = "claude-3-haiku-20240307";
const REQUESTED_MODEL_ID = Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_MODEL") ||
  Deno.env.get("AUDIT_ATTRIBUTION_MODEL") ||
  SAFE_FALLBACK_MODEL_ID;
const FALLBACK_MODEL_ID = Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_MODEL_FALLBACK") ||
  Deno.env.get("AUDIT_ATTRIBUTION_MODEL_FALLBACK") || SAFE_FALLBACK_MODEL_ID;
const PROMPT_VERSION = Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_PROMPT_VERSION") || "prod_attrib_audit_reviewer_v0";
const MAX_TOKENS = Number(Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_MAX_TOKENS") || "1400");
const LLM_TIMEOUT_MS = Number(Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_TIMEOUT_MS") || "18000");

const ALLOWED_SOURCES = [
  "prod-attrib-audit-runner",
  "audit-attribution-reviewer",
  "audit-attribution-test",
  "segment-call",
  "manual",
  "m2-gt-eval",
  "cron",
];

const JSON_HEADERS = { "Content-Type": "application/json" };

const SYSTEM_PROMPT = `You are an impartial attribution reviewer for production audit packets.
You must use ONLY the provided packet content.
Do NOT assume missing context.
Do NOT fetch or invent external facts.

Question:
"Given only this evidence packet and as-of project context, is the assigned project the best match? If not, what are top competing candidates and why? Cite anchors tied to provided facts/pointers. If insufficient evidence, verdict=INSUFFICIENT and list missing evidence."

Output strict JSON with keys:
- verdict: MATCH | MISMATCH | INSUFFICIENT
- top_candidates: [{project_id, confidence, anchor_rationale}]
- missing_evidence: [string]
- failure_mode_tags: [string]
- rationale_anchors: [{anchor, source}]
- notes: short string

Rules:
- If evidence cannot justify assignment, return INSUFFICIENT.
- If a better candidate exists in packet evidence, return MISMATCH.
- Keep confidence in [0,1].
- Use concise factual notes only.`;

type JsonRecord = Record<string, unknown>;

interface TopCandidate {
  project_id: string | null;
  confidence: number;
  anchor_rationale: string;
}

interface RationaleAnchor {
  anchor: string;
  source: string;
}

interface ReviewerOutput {
  verdict: "MATCH" | "MISMATCH" | "INSUFFICIENT";
  top_candidates: TopCandidate[];
  missing_evidence: string[];
  failure_mode_tags: string[];
  rationale_anchors: RationaleAnchor[];
  notes: string;
}

interface NormalizedPacket {
  interaction_id: string;
  span_id: string;
  span_attribution_id: string;
  assigned_project_id: string;
  assigned_decision: string;
  assigned_confidence: number | null;
  assigned_evidence_tier: number | null;
  attribution_source: string;
  transcript_segment: string;
  span_bounds: JsonRecord;
  project_context_as_of: JsonRecord[];
  evidence_events: JsonRecord[];
  claim_pointers: JsonRecord[];
  evidence_event_id: string;
  call_at_utc: string;
  asof_mode: string;
  same_call_excluded: boolean;
}

interface NormalizedRequest {
  packet_json: JsonRecord;
  packet: NormalizedPacket;
}

function asRecord(v: unknown): JsonRecord {
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as JsonRecord) : {};
}

function asString(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function asNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim()) {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function clampConfidence(v: unknown): number {
  const n = asNumber(v) ?? 0;
  if (n < 0) return 0;
  if (n > 1) return 1;
  return Number(n.toFixed(4));
}

function uniqueStrings(values: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    const s = v.trim();
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

function normalizeStringArray(v: unknown, limit = 24, maxLen = 160): string[] {
  const arr = asArray(v)
    .map((x) => asString(x))
    .filter(Boolean)
    .map((x) => x.slice(0, maxLen));
  return uniqueStrings(arr).slice(0, limit);
}

function normalizeAnchors(v: unknown): RationaleAnchor[] {
  const arr = asArray(v).slice(0, 20);
  return arr.map((item) => {
    const r = asRecord(item);
    return {
      anchor: asString(r.anchor || r.quote || r.text).slice(0, 260),
      source: asString(r.source || r.type || "packet").slice(0, 64) || "packet",
    };
  }).filter((x) => x.anchor.length > 0);
}

function normalizeTopCandidates(v: unknown): TopCandidate[] {
  const arr = asArray(v).slice(0, 3);
  return arr.map((item) => {
    const r = asRecord(item);
    const projectId = asString(r.project_id || r.id || r.candidate_project_id);
    return {
      project_id: projectId || null,
      confidence: clampConfidence(r.confidence),
      anchor_rationale: asString(r.anchor_rationale || r.rationale || r.reason).slice(0, 360),
    };
  }).filter((x) => x.project_id || x.anchor_rationale);
}

function normalizeVerdict(v: unknown): ReviewerOutput["verdict"] {
  const raw = asString(v).toUpperCase();
  if (raw === "MATCH" || raw === "MISMATCH" || raw === "INSUFFICIENT") return raw;
  return "INSUFFICIENT";
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function asUuid(v: unknown): string | null {
  const s = asString(v);
  if (!s || !UUID_RE.test(s)) return null;
  return s.toLowerCase();
}

function normalizeToken(v: string, maxLen: number): string {
  return v
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, maxLen);
}

function normalizeTagList(values: string[]): string[] {
  return uniqueStrings(values.map((v) => normalizeToken(v, 80)).filter(Boolean)).slice(0, 24);
}

function normalizeMissingEvidenceList(values: string[]): string[] {
  return uniqueStrings(values.map((v) => normalizeToken(v, 180)).filter(Boolean)).slice(0, 24);
}

function parseTimestampMs(v: unknown): number | null {
  const s = asString(v);
  if (!s) return null;
  const parsed = Date.parse(s);
  return Number.isFinite(parsed) ? parsed : null;
}

function canonicalizeJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((item) => canonicalizeJson(item));
  if (value && typeof value === "object") {
    const record = value as JsonRecord;
    const out: JsonRecord = {};
    for (const key of Object.keys(record).sort()) {
      const v = record[key];
      if (v === undefined) continue;
      out[key] = canonicalizeJson(v);
    }
    return out;
  }
  return value;
}

function parsePacket(body: JsonRecord): NormalizedRequest {
  const packetLike = asRecord(body.packet_json || body.audit_packet || body.audit_packet_json || body.packet);
  const merged = Object.keys(packetLike).length > 0 ? packetLike : body;
  const packetJson = canonicalizeJson(merged) as JsonRecord;

  const evidencePacket = asRecord(merged.evidence_packet);
  const assignedAttribution = asRecord(merged.assigned_attribution);
  const legacySpan = asRecord(merged.span);
  const legacySpanText = asRecord(merged.span_text);
  const legacyPointer = asRecord(legacySpanText.pointer);
  const legacyAttribution = asRecord(merged.attribution);
  const legacyAsOf = asRecord(merged.as_of_world_model);
  const legacySpanBounds = asRecord(merged.span_bounds || legacySpan || legacyPointer);
  const interactionId = asString(merged.interaction_id || legacySpan.interaction_id || legacyPointer.interaction_id);
  const spanId = asString(merged.span_id || legacySpan.span_id || legacyPointer.span_id);
  const transcriptSegment = asString(
    merged.transcript_segment || legacySpanBounds.transcript_segment || legacySpanText.text,
  );
  const callAtUtc = asString(merged.call_at_utc || legacyAsOf.call_time_utc);
  const assignedProjectId = asString(
    merged.assigned_project_id || merged.project_id || assignedAttribution.project_id ||
      legacyAttribution.attributed_project_id || legacyAttribution.project_id,
  );

  const projectContextRaw = asArray(
    merged.project_context_as_of || merged.as_of_project_context ||
      legacyAsOf.assigned_project_facts,
  )
    .map(asRecord);
  const candidateProjectMap = new Map<string, string>();
  const competingCandidates = asArray(merged.competing_candidates).map(asRecord);
  for (const candidate of competingCandidates) {
    const projectId = asUuid(candidate.project_id || candidate.id);
    if (!projectId) continue;
    if (!candidateProjectMap.has(projectId)) {
      candidateProjectMap.set(projectId, asString(candidate.project_name || candidate.name));
    }
  }
  for (
    const candidateProjectId of asArray(merged.candidate_project_ids)
      .map((id) => asUuid(id))
      .filter((id): id is string => Boolean(id))
  ) {
    if (!candidateProjectMap.has(candidateProjectId)) {
      candidateProjectMap.set(candidateProjectId, "");
    }
  }
  const assignedProjectUuid = asUuid(assignedProjectId);
  if (assignedProjectUuid && !candidateProjectMap.has(assignedProjectUuid)) {
    candidateProjectMap.set(assignedProjectUuid, "");
  }
  const fallbackProjectContext = Array.from(candidateProjectMap.entries()).slice(0, 12).map((
    [projectId, projectName],
  ) => ({
    project_id: projectId,
    fact_kind: "project_metadata_fallback",
    as_of_at: callAtUtc || null,
    observed_at: callAtUtc || null,
    evidence_event_id: null,
    source_span_id: spanId || null,
    source_char_start: asNumber(legacySpanBounds.char_start),
    source_char_end: asNumber(legacySpanBounds.char_end),
    interaction_id: null,
    fact_payload: {
      project_name: projectName || null,
      source: "packet_candidate_fallback",
      note: "project_context_fallback_from_candidate_ids",
    },
  }));
  const projectContext = projectContextRaw.length > 0 ? projectContextRaw : fallbackProjectContext;

  const evidenceEventsRaw = asArray(merged.evidence_events || evidencePacket.evidence_events).map(asRecord);
  const evidenceEventsFromIds = asArray(merged.evidence_event_ids || evidencePacket.evidence_event_ids)
    .map((id) => asUuid(id))
    .filter((id): id is string => Boolean(id))
    .map((id) => ({ evidence_event_id: id, source: "packet_evidence_event_ids" }));
  const legacyEvidencePtrs = asArray(merged.evidence_ptrs)
    .map((id) => asUuid(id))
    .filter((id): id is string => Boolean(id))
    .map((id) => ({ evidence_event_id: id }));
  const evidenceEvents = evidenceEventsRaw.length > 0
    ? evidenceEventsRaw
    : [...evidenceEventsFromIds, ...legacyEvidencePtrs];
  const claimPointersRaw = asArray(merged.claim_pointers || evidencePacket.claim_pointers).map(asRecord);
  const transcriptFallbackPointer = (
      claimPointersRaw.length === 0 &&
      transcriptSegment.length > 0
    )
    ? [{
      pointer_kind: "transcript_span_fallback",
      source_type: "conversation_spans",
      source_id: interactionId || null,
      span_id: spanId || null,
      char_start: asNumber(legacySpanBounds.char_start),
      char_end: asNumber(legacySpanBounds.char_end),
      span_text: transcriptSegment.slice(0, 1600),
    }]
    : [];
  const claimPointers = claimPointersRaw.length > 0 ? claimPointersRaw : transcriptFallbackPointer;

  return {
    packet_json: packetJson,
    packet: {
      interaction_id: interactionId,
      span_id: spanId,
      span_attribution_id: asString(
        merged.span_attribution_id || assignedAttribution.span_attribution_id || legacyAttribution.span_attribution_id,
      ),
      assigned_project_id: assignedProjectId,
      assigned_decision: asString(
        merged.assigned_decision || assignedAttribution.decision || legacyAttribution.decision,
      ),
      assigned_confidence: asNumber(
        merged.assigned_confidence || assignedAttribution.confidence || legacyAttribution.confidence,
      ),
      assigned_evidence_tier: asNumber(
        merged.assigned_evidence_tier || assignedAttribution.evidence_tier || legacyAttribution.evidence_tier,
      ),
      attribution_source: asString(
        merged.attribution_source || assignedAttribution.attribution_source || legacyAttribution.attribution_source ||
          merged.source,
      ),
      transcript_segment: transcriptSegment,
      span_bounds: legacySpanBounds,
      project_context_as_of: projectContext,
      evidence_events: evidenceEvents,
      claim_pointers: claimPointers,
      evidence_event_id: asString(merged.evidence_event_id || legacyAttribution.evidence_event_id),
      call_at_utc: callAtUtc,
      asof_mode: asString(merged.asof_mode || merged.known_as_of_mode || legacyAsOf.mode || "KNOWN_AS_OF") ||
        "KNOWN_AS_OF",
      same_call_excluded: merged.same_call_excluded !== false &&
        legacyAsOf.same_call_excluded !== false,
    },
  };
}

function extractEvidenceEventIds(packet: NormalizedPacket): string[] {
  const ids = asArray(packet.evidence_events)
    .map((eventObj) => asRecord(eventObj))
    .map((eventObj) => asUuid(eventObj.evidence_event_id || eventObj.event_id || eventObj.id))
    .filter((id): id is string => Boolean(id));
  const singleton = asUuid(packet.evidence_event_id);
  if (singleton) ids.push(singleton);
  return uniqueStrings(ids).slice(0, 64);
}

function packetLeakageDetected(packet: NormalizedPacket): boolean {
  const sameInteraction = packet.project_context_as_of.some((fact) => {
    const interactionRef = asString(
      fact.interaction_id || fact.source_interaction_id || fact.call_id || fact.source_id,
    );
    return Boolean(interactionRef && packet.interaction_id && interactionRef === packet.interaction_id);
  });
  if (sameInteraction) return true;

  const packetEventIds = new Set(extractEvidenceEventIds(packet));
  if (packetEventIds.size === 0) return false;

  for (const factObj of packet.project_context_as_of) {
    const fact = asRecord(factObj);
    const factEventIds = [
      asUuid(fact.evidence_event_id),
      asUuid(fact.event_id),
      asUuid(fact.source_evidence_event_id),
      asUuid(fact.source_event_id),
    ].filter((id): id is string => Boolean(id));
    for (const id of factEventIds) {
      if (packetEventIds.has(id)) return true;
    }
  }

  return false;
}

function packetFutureLeakageDetected(packet: NormalizedPacket): boolean {
  const callTs = parseTimestampMs(packet.call_at_utc);
  if (callTs === null) return false;

  for (const factObj of packet.project_context_as_of) {
    const fact = asRecord(factObj);
    const factTs = parseTimestampMs(fact.observed_at) ??
      parseTimestampMs(fact.as_of_at) ??
      parseTimestampMs(fact.created_at);
    if (factTs !== null && factTs > callTs) return true;
  }
  return false;
}

function buildUserPrompt(packet: NormalizedPacket): string {
  const packetPreview = {
    interaction_id: packet.interaction_id,
    span_id: packet.span_id,
    span_attribution_id: packet.span_attribution_id,
    assigned_project_id: packet.assigned_project_id,
    assigned_decision: packet.assigned_decision,
    assigned_confidence: packet.assigned_confidence,
    assigned_evidence_tier: packet.assigned_evidence_tier,
    attribution_source: packet.attribution_source,
    asof_mode: packet.asof_mode,
    same_call_excluded: packet.same_call_excluded,
    call_at_utc: packet.call_at_utc,
    span_bounds: packet.span_bounds,
    transcript_segment: packet.transcript_segment.slice(0, 2800),
    project_context_as_of: packet.project_context_as_of.slice(0, 30),
    evidence_events: packet.evidence_events.slice(0, 16),
    claim_pointers: packet.claim_pointers.slice(0, 16),
  };
  return `Review this packet:\n${JSON.stringify(packetPreview, null, 2)}`;
}

function shouldRetryModelFallback(errorMessage: string): boolean {
  const msg = errorMessage.toLowerCase();
  return (
    msg.includes("not_found_error") ||
    (msg.includes("model") && msg.includes("not found")) ||
    (msg.includes("404") && msg.includes("model"))
  );
}

function parseAnthropicTextContent(llmResp: unknown): string {
  const contentBlocks = asArray(asRecord(llmResp).content).map(asRecord);
  const textChunks = contentBlocks
    .filter((b) => asString(b.type) === "text")
    .map((b) => asString(b.text))
    .filter(Boolean)
    .slice(0, 4);
  return textChunks.join("\n");
}

function listCandidateModels(requested: string, configuredFallback: string): string[] {
  return uniqueStrings([
    requested,
    configuredFallback,
    SAFE_FALLBACK_MODEL_ID,
  ].filter((modelId) => modelId && modelId.trim().length > 0));
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: { ...JSON_HEADERS, "Access-Control-Allow-Headers": "content-type,x-edge-secret,x-source" },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), {
      status: 405,
      headers: JSON_HEADERS,
    });
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code || "missing_edge_secret");

  let body: JsonRecord = {};
  try {
    body = asRecord(await req.json());
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "invalid_json" }), {
      status: 400,
      headers: JSON_HEADERS,
    });
  }

  const normalized = parsePacket(body);
  const packet = normalized.packet;

  if (!packet.interaction_id || !packet.span_id) {
    return new Response(JSON.stringify({ ok: false, error: "missing_required_ids" }), {
      status: 400,
      headers: JSON_HEADERS,
    });
  }

  const deterministicTags: string[] = [];
  const deterministicMissing: string[] = [];
  const leakageDetected = packetLeakageDetected(packet);
  const futureLeakageDetected = packetFutureLeakageDetected(packet);
  const packetEventIds = extractEvidenceEventIds(packet);

  if (asString(packet.asof_mode).toUpperCase() !== "KNOWN_AS_OF") {
    deterministicTags.push("asof_mode_not_known_as_of");
    deterministicMissing.push("known_as_of_mode");
  }
  if (packet.same_call_excluded !== true) {
    deterministicTags.push("same_call_exclusion_not_asserted");
    deterministicMissing.push("same_call_excluded=true");
  }
  if (!packet.assigned_project_id) {
    deterministicTags.push("missing_assigned_project");
    deterministicMissing.push("assigned_project_id");
  }
  if (packet.assigned_decision === "assign") {
    const conf = packet.assigned_confidence;
    if (conf === null || conf < 0 || conf > 1) {
      deterministicTags.push("fake_assigned_confidence");
      deterministicMissing.push("assigned_confidence_in_[0,1]");
    }
    if ((conf ?? 0) > 0 && packetEventIds.length === 0 && packet.claim_pointers.length === 0) {
      deterministicTags.push("fake_assigned_confidence_no_evidence");
      deterministicMissing.push("evidence_events_or_claim_pointers");
    }
  }
  if (!packet.transcript_segment) {
    deterministicTags.push("missing_transcript_segment");
    deterministicMissing.push("transcript_segment");
  }
  if (packet.project_context_as_of.length === 0) {
    deterministicTags.push("missing_project_context");
    deterministicMissing.push("as_of_project_context");
    deterministicTags.push("provenance_context_missing");
  }
  if (packet.evidence_events.length === 0 && packet.claim_pointers.length === 0) {
    deterministicTags.push("missing_evidence_packet");
    deterministicMissing.push("evidence_events_or_claim_pointers");
    deterministicTags.push("pointer_or_provenance_gap");
    deterministicTags.push("insufficient_provenance_pointer_quality");
  }
  if (packet.evidence_events.length === 0 && packet.claim_pointers.length === 0) {
    deterministicTags.push("missing_evidence_events");
    deterministicMissing.push("evidence_events");
    deterministicTags.push("provenance_context_missing");
    deterministicTags.push("insufficient_provenance_pointer_quality");
  }
  if (leakageDetected) {
    deterministicTags.push("same_call_leakage_detected");
    deterministicMissing.push("clean_as_of_context_without_same_call_facts");
  }
  if (futureLeakageDetected) {
    deterministicTags.push("future_context_leakage_detected");
    deterministicMissing.push("as_of_project_context_observed_at<=call_at_utc");
  }

  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") || "" });
  let output: ReviewerOutput;
  let llmParseMode = "none";
  let llmRawPreview = "";
  let usedModelId = REQUESTED_MODEL_ID;

  try {
    const callReviewer = async (modelId: string) => {
      return await Promise.race([
        anthropic.messages.create({
          model: modelId,
          max_tokens: MAX_TOKENS,
          system: SYSTEM_PROMPT,
          messages: [{ role: "user", content: buildUserPrompt(packet) }],
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("llm_timeout")), LLM_TIMEOUT_MS)),
      ]);
    };

    const candidateModels = listCandidateModels(REQUESTED_MODEL_ID, FALLBACK_MODEL_ID);
    let llmResp: unknown = null;
    let lastModelError: unknown = null;
    for (let i = 0; i < candidateModels.length; i++) {
      const candidateModel = candidateModels[i];
      usedModelId = candidateModel;
      try {
        llmResp = await callReviewer(candidateModel);
        lastModelError = null;
        break;
      } catch (e: unknown) {
        lastModelError = e;
        const errMsg = e instanceof Error ? e.message : String(e || "");
        const canRetry = i < candidateModels.length - 1 && shouldRetryModelFallback(errMsg);
        if (!canRetry) {
          throw e;
        }
      }
    }
    if (!llmResp && lastModelError) {
      throw lastModelError;
    }

    const rawText = parseAnthropicTextContent(llmResp);
    llmRawPreview = rawText.slice(0, 500);
    const parsed = parseLlmJson<JsonRecord>(rawText);
    llmParseMode = parsed.parseMode;
    const llm = asRecord(parsed.value);

    output = {
      verdict: normalizeVerdict(llm.verdict),
      top_candidates: normalizeTopCandidates(llm.top_candidates),
      missing_evidence: normalizeStringArray(llm.missing_evidence, 24, 180),
      failure_mode_tags: normalizeStringArray(llm.failure_mode_tags, 24, 80),
      rationale_anchors: normalizeAnchors(llm.rationale_anchors),
      notes: asString(llm.notes).slice(0, 500),
    };
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e || "unknown");
    output = {
      verdict: "INSUFFICIENT",
      top_candidates: [],
      missing_evidence: ["reviewer_llm_unavailable"],
      failure_mode_tags: ["reviewer_runtime_error"],
      rationale_anchors: [],
      notes: `LLM reviewer unavailable: ${msg}`.slice(0, 500),
    };
  }

  output.missing_evidence = normalizeMissingEvidenceList([...output.missing_evidence, ...deterministicMissing]);
  output.failure_mode_tags = normalizeTagList([...output.failure_mode_tags, ...deterministicTags]);

  const assignedProjectUuid = asUuid(packet.assigned_project_id);
  const topCandidateProjectUuid = asUuid(output.top_candidates[0]?.project_id);
  if (assignedProjectUuid && topCandidateProjectUuid && topCandidateProjectUuid !== assignedProjectUuid) {
    output.verdict = "MISMATCH";
    output.failure_mode_tags = normalizeTagList([
      ...output.failure_mode_tags,
      "top_candidate_disagrees_with_assignment",
      "assignment_disagreement",
    ]);
    if (!output.notes) output.notes = "forced_mismatch_due_to_top_candidate_assignment_disagreement";
  }

  if (
    output.verdict === "MATCH" &&
    (
      output.failure_mode_tags.includes("missing_project_context") ||
      output.failure_mode_tags.includes("missing_evidence_packet") ||
      output.failure_mode_tags.includes("missing_evidence_events") ||
      output.failure_mode_tags.includes("provenance_context_missing") ||
      output.failure_mode_tags.includes("pointer_or_provenance_gap") ||
      output.failure_mode_tags.includes("insufficient_provenance_pointer_quality")
    )
  ) {
    output.verdict = "INSUFFICIENT";
    output.notes = (output.notes
      ? `${output.notes} | forced_insufficient_due_to_missing_provenance`
      : "forced_insufficient_due_to_missing_provenance").slice(0, 500);
  }

  if (output.verdict === "MISMATCH") {
    output.failure_mode_tags = normalizeTagList([...output.failure_mode_tags, "assignment_disagreement"]);
  }

  if (output.verdict === "MATCH" && output.failure_mode_tags.includes("same_call_leakage_detected")) {
    output.verdict = "INSUFFICIENT";
    output.notes = (output.notes
      ? `${output.notes} | forced_insufficient_due_to_same_call_leakage`
      : "forced_insufficient_due_to_same_call_leakage").slice(0, 500);
  }

  if (
    output.verdict === "MATCH" &&
    (
      output.failure_mode_tags.includes("future_context_leakage_detected") ||
      output.failure_mode_tags.includes("asof_mode_not_known_as_of") ||
      output.failure_mode_tags.includes("same_call_exclusion_not_asserted") ||
      output.failure_mode_tags.includes("fake_assigned_confidence") ||
      output.failure_mode_tags.includes("fake_assigned_confidence_no_evidence")
    )
  ) {
    output.verdict = "INSUFFICIENT";
    output.notes = (output.notes
      ? `${output.notes} | forced_insufficient_due_to_guardrail_violation`
      : "forced_insufficient_due_to_guardrail_violation").slice(0, 500);
  }

  if (output.verdict === "MATCH" && !packet.assigned_project_id) {
    output.verdict = "INSUFFICIENT";
  }

  return new Response(
    JSON.stringify({
      ok: true,
      function_slug: FUNCTION_SLUG,
      version: FUNCTION_VERSION,
      model_id: usedModelId,
      prompt_version: PROMPT_VERSION,
      source: auth.source || null,
      ms: Date.now() - t0,
      reviewer_output: output,
      deterministic_checks: {
        failure_mode_tags: deterministicTags,
        missing_evidence: deterministicMissing,
      },
      guardrail_summary: {
        same_call_leakage_detected: leakageDetected,
        future_context_leakage_detected: futureLeakageDetected,
        same_call_excluded: packet.same_call_excluded,
        asof_mode: packet.asof_mode,
      },
      llm_parse_mode: llmParseMode,
      llm_raw_preview: llmRawPreview,
      packet_preview: {
        interaction_id: packet.interaction_id,
        span_id: packet.span_id,
        span_attribution_id: packet.span_attribution_id,
        assigned_project_id: packet.assigned_project_id || null,
        assigned_decision: packet.assigned_decision || null,
        evidence_event_ids: packetEventIds,
      },
      packet_json: normalized.packet_json,
    }),
    { status: 200, headers: JSON_HEADERS },
  );
});
