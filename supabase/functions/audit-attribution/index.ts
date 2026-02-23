/**
 * audit-attribution Edge Function v0.1.0
 *
 * Purpose:
 * - Execute impartial reviewer judgment for attribution audit packets.
 * - Persist reviewer outputs onto eval_samples for standing audit runs.
 *
 * Hard constraints:
 * - Packet-in only: no context-fetch reads for review reasoning.
 * - No future leakage: enforce packet-level same-call context guard.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk@0.39.0";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";
import { parseLlmJson } from "../_shared/llm_json.ts";

const FUNCTION_VERSION = "v0.1.1";
const SAFE_FALLBACK_MODEL_ID = "claude-3-haiku-20240307";
const REQUESTED_MODEL_ID = Deno.env.get("AUDIT_ATTRIBUTION_MODEL") ||
  Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_MODEL") ||
  SAFE_FALLBACK_MODEL_ID;
const FALLBACK_MODEL_ID = Deno.env.get("AUDIT_ATTRIBUTION_MODEL_FALLBACK") ||
  Deno.env.get("AUDIT_ATTRIBUTION_REVIEWER_MODEL_FALLBACK") ||
  SAFE_FALLBACK_MODEL_ID;
const PROMPT_VERSION = Deno.env.get("AUDIT_ATTRIBUTION_PROMPT_VERSION") || "prod_attrib_audit_v1";
const REVIEWER_PROVIDER = "anthropic";
const MAX_TOKENS = Number(Deno.env.get("AUDIT_ATTRIBUTION_MAX_TOKENS") || "1400");
const LLM_TIMEOUT_MS = Number(Deno.env.get("AUDIT_ATTRIBUTION_TIMEOUT_MS") || "18000");
const JSON_HEADERS = { "Content-Type": "application/json" };

const ALLOWED_SOURCES = [
  "prod-attrib-audit-runner",
  "segment-call",
  "manual",
  "m2-gt-eval",
  "audit-attribution-test",
  "cron",
];

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
  attribution_source: string;
  span_bounds: JsonRecord;
  transcript_segment: string;
  project_context_as_of: JsonRecord[];
  evidence_events: JsonRecord[];
  claim_pointers: JsonRecord[];
  evidence_event_id: string;
  call_at_utc: string;
  asof_mode: string;
  same_call_excluded: boolean;
  assigned_decision: string;
  assigned_confidence: number | null;
  assigned_evidence_tier: number | null;
}

interface NormalizedRequest {
  eval_sample_id: string;
  persist: boolean;
  dry_run: boolean;
  reviewer_run_id: string;
  packet_json: JsonRecord;
  packet: NormalizedPacket;
}

const SYSTEM_PROMPT = `You are an impartial attribution reviewer for production audit packets.
You must use ONLY the provided packet content.
Do NOT assume missing context.
Do NOT fetch or invent external facts.

Question:
"Given only this evidence packet and as-of project context, is the assigned project the best match? If not, what are top 3 candidates and why? Cite anchors tied to provided facts/pointers. If insufficient evidence, say cannot justify and list what evidence is missing."

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

function parsePacket(body: JsonRecord): NormalizedRequest {
  const packetLike = asRecord(body.packet_json || body.audit_packet || body.audit_packet_json || body.packet);
  const merged = Object.keys(packetLike).length > 0 ? packetLike : body;
  const packetJson = Object.keys(packetLike).length > 0 ? packetLike : { ...merged };
  delete packetJson.eval_sample_id;
  delete packetJson.persist;
  delete packetJson.dry_run;
  delete packetJson.reviewer_run_id;
  delete packetJson.audit_packet;
  delete packetJson.audit_packet_json;
  delete packetJson.packet;
  const evidencePacket = asRecord(merged.evidence_packet);
  const assignedAttribution = asRecord(merged.assigned_attribution);
  const spanObj = asRecord(merged.span);
  const attributionObj = asRecord(merged.attribution);
  const spanTextObj = asRecord(merged.span_text);
  const asOfWorldModel = asRecord(merged.as_of_world_model);
  const spanBounds = asRecord(merged.span_bounds || merged.span);
  const transcriptSegment = asString(merged.transcript_segment || spanBounds.transcript_segment || spanTextObj.text);
  const interactionId = asString(merged.interaction_id || spanObj.interaction_id);
  const spanId = asString(merged.span_id || spanObj.span_id);
  const callAtUtc = asString(merged.call_at_utc || asOfWorldModel.call_time_utc);
  const assignedProjectId = asString(
    merged.assigned_project_id ||
      merged.project_id ||
      assignedAttribution.project_id ||
      attributionObj.attributed_project_id ||
      attributionObj.project_id,
  );

  const evidenceEventsFromPtrs = asArray(merged.evidence_ptrs)
    .map((ptr) => asUuid(ptr))
    .filter((id): id is string => Boolean(id))
    .map((evidenceEventId) => ({
      evidence_event_id: evidenceEventId,
      source: "packet_evidence_ptr",
    }));
  const evidenceEventsFromIds = asArray(merged.evidence_event_ids || evidencePacket.evidence_event_ids)
    .map((ptr) => asUuid(ptr))
    .filter((id): id is string => Boolean(id))
    .map((evidenceEventId) => ({
      evidence_event_id: evidenceEventId,
      source: "packet_evidence_event_ids",
    }));
  const evidenceEventsRaw = asArray(
    merged.evidence_events || evidencePacket.evidence_events ||
      evidenceEventsFromPtrs,
  ).map(asRecord);
  const evidenceEvents = evidenceEventsRaw.length > 0 ? evidenceEventsRaw : evidenceEventsFromIds;

  const claimPointersRaw = asArray(
    merged.claim_pointers || evidencePacket.claim_pointers,
  ).map(asRecord);
  const transcriptFallbackPointer = (
      claimPointersRaw.length === 0 &&
      transcriptSegment.length > 0
    )
    ? [{
      pointer_kind: "transcript_span_fallback",
      source_type: "conversation_spans",
      source_id: interactionId || null,
      span_id: spanId || null,
      char_start: asNumber(spanBounds.char_start),
      char_end: asNumber(spanBounds.char_end),
      span_text: transcriptSegment.slice(0, 1600) || null,
    }]
    : [];
  const claimPointers = claimPointersRaw.length > 0 ? claimPointersRaw : transcriptFallbackPointer;

  const projectContextRaw = asArray(
    merged.project_context_as_of || merged.as_of_project_context || asOfWorldModel.assigned_project_facts,
  ).map(asRecord);
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
    source_char_start: asNumber(spanBounds.char_start),
    source_char_end: asNumber(spanBounds.char_end),
    interaction_id: null,
    fact_payload: {
      project_name: projectName || null,
      source: "packet_candidate_fallback",
      note: "project_context_fallback_from_candidate_ids",
    },
  }));
  const projectContext = projectContextRaw.length > 0 ? projectContextRaw : fallbackProjectContext;

  const req: NormalizedRequest = {
    eval_sample_id: asString(body.eval_sample_id || merged.eval_sample_id),
    persist: body.persist !== false,
    dry_run: body.dry_run === true,
    reviewer_run_id: asString(body.reviewer_run_id || merged.reviewer_run_id || merged.eval_run_id),
    packet_json: packetJson,
    packet: {
      interaction_id: interactionId,
      span_id: spanId,
      span_attribution_id: asString(
        merged.span_attribution_id || assignedAttribution.span_attribution_id || attributionObj.span_attribution_id,
      ),
      assigned_project_id: assignedProjectId,
      attribution_source: asString(
        merged.attribution_source || assignedAttribution.attribution_source || attributionObj.attribution_source ||
          merged.source,
      ),
      span_bounds: spanBounds,
      transcript_segment: transcriptSegment,
      project_context_as_of: projectContext,
      evidence_events: evidenceEvents,
      claim_pointers: claimPointers,
      evidence_event_id: asString(merged.evidence_event_id || attributionObj.evidence_event_id),
      call_at_utc: callAtUtc,
      asof_mode: asString(merged.asof_mode || merged.known_as_of_mode || asOfWorldModel.mode || "KNOWN_AS_OF") ||
        "KNOWN_AS_OF",
      same_call_excluded:
        (typeof merged.same_call_excluded === "boolean"
          ? merged.same_call_excluded
          : asOfWorldModel.same_call_excluded) !== false,
      assigned_decision: asString(merged.assigned_decision || assignedAttribution.decision || attributionObj.decision),
      assigned_confidence: asNumber(
        merged.assigned_confidence || assignedAttribution.confidence || attributionObj.confidence,
      ),
      assigned_evidence_tier: asNumber(
        merged.assigned_evidence_tier || assignedAttribution.evidence_tier || attributionObj.evidence_tier,
      ),
    },
  };

  return req;
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

function packetLeakageDetected(packet: NormalizedPacket): boolean {
  for (const fact of packet.project_context_as_of) {
    const interactionRef = asString(
      fact.interaction_id || fact.source_interaction_id || fact.call_id || fact.source_id,
    );
    if (interactionRef && packet.interaction_id && interactionRef === packet.interaction_id) {
      return true;
    }
  }
  return false;
}

function parseTimestampMs(v: unknown): number | null {
  const s = asString(v);
  if (!s) return null;
  const parsed = Date.parse(s);
  return Number.isFinite(parsed) ? parsed : null;
}

function packetFutureLeakageDetected(packet: NormalizedPacket): boolean {
  const callTs = parseTimestampMs(packet.call_at_utc);
  if (callTs === null) return false;

  for (const factObj of packet.project_context_as_of) {
    const fact = asRecord(factObj);
    const factTs = parseTimestampMs(fact.observed_at) ??
      parseTimestampMs(fact.as_of_at) ??
      parseTimestampMs(fact.created_at);
    if (factTs !== null && factTs > callTs) {
      return true;
    }
  }
  return false;
}

function buildUserPrompt(packet: NormalizedPacket): string {
  const packetPreview = {
    interaction_id: packet.interaction_id,
    span_id: packet.span_id,
    assigned_project_id: packet.assigned_project_id,
    assigned_decision: packet.assigned_decision,
    assigned_confidence: packet.assigned_confidence,
    assigned_evidence_tier: packet.assigned_evidence_tier,
    span_bounds: packet.span_bounds,
    transcript_segment: packet.transcript_segment.slice(0, 2400),
    project_context_as_of: packet.project_context_as_of.slice(0, 25),
    evidence_events: packet.evidence_events.slice(0, 12),
    claim_pointers: packet.claim_pointers.slice(0, 12),
  };
  return `Review this packet:\n${JSON.stringify(packetPreview, null, 2)}`;
}

function canonicalizeJson(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalizeJson(item));
  }
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

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function parseTimestampOrNow(v: string): string {
  const parsed = Date.parse(v);
  if (Number.isFinite(parsed)) {
    return new Date(parsed).toISOString();
  }
  return new Date().toISOString();
}

function extractEvidenceEventIds(packet: NormalizedPacket): string[] {
  const ids = asArray(packet.evidence_events)
    .map((eventObj) => asRecord(eventObj))
    .map((eventObj) => asUuid(eventObj.evidence_event_id))
    .filter((id): id is string => Boolean(id));

  const singleton = asUuid(packet.evidence_event_id);
  if (singleton) {
    ids.push(singleton);
  }
  return uniqueStrings(ids).slice(0, 32);
}

async function countByStatus(db: any, evalRunId: string, status: string): Promise<number> {
  const { count } = await db
    .from("eval_samples")
    .select("*", { count: "exact", head: true })
    .eq("eval_run_id", evalRunId)
    .eq("status", status);
  return count || 0;
}

async function countReviewed(db: any, evalRunId: string): Promise<number> {
  const { count } = await db
    .from("eval_samples")
    .select("*", { count: "exact", head: true })
    .eq("eval_run_id", evalRunId)
    .not("reviewer_completed_at", "is", null);
  return count || 0;
}

async function countTotal(db: any, evalRunId: string): Promise<number> {
  const { count } = await db
    .from("eval_samples")
    .select("*", { count: "exact", head: true })
    .eq("eval_run_id", evalRunId);
  return count || 0;
}

async function persistToEvalSample(
  db: any,
  evalSampleId: string,
  output: ReviewerOutput,
  meta: JsonRecord,
  modelId: string,
): Promise<{ eval_run_id: string; sample_status: string }> {
  const { data: sample, error: sampleErr } = await db
    .from("eval_samples")
    .select("id, eval_run_id, scoreboard_json")
    .eq("id", evalSampleId)
    .maybeSingle();

  if (sampleErr) throw new Error(`eval_sample_lookup_failed: ${sampleErr.message}`);
  if (!sample) throw new Error(`eval_sample_not_found: ${evalSampleId}`);

  const nowIso = new Date().toISOString();
  const sampleStatus = output.verdict === "MATCH" ? "pass" : "fail";
  const scoreboard = asRecord(sample.scoreboard_json);
  const mergedScoreboard = {
    ...scoreboard,
    attribution_reviewer: {
      function_version: FUNCTION_VERSION,
      model_id: modelId,
      verdict: output.verdict,
      failure_mode_tags: output.failure_mode_tags,
      top_candidates_count: output.top_candidates.length,
      reviewed_at_utc: nowIso,
      meta,
    },
  };

  const { error: updateErr } = await db
    .from("eval_samples")
    .update({
      reviewer_verdict: output.verdict,
      reviewer_top_candidates: output.top_candidates,
      reviewer_missing_evidence: output.missing_evidence,
      reviewer_failure_mode_tags: output.failure_mode_tags,
      reviewer_rationale_anchors: output.rationale_anchors,
      reviewer_notes: output.notes,
      reviewer_completed_at: nowIso,
      scoreboard_json: mergedScoreboard,
      status: sampleStatus,
      completed_at: nowIso,
      started_at: nowIso,
    })
    .eq("id", evalSampleId);

  if (updateErr) throw new Error(`eval_sample_update_failed: ${updateErr.message}`);

  const evalRunId = asString(sample.eval_run_id);
  if (evalRunId) {
    try {
      const [totalSamples, passCount, failCount, reviewedCount] = await Promise.all([
        countTotal(db, evalRunId),
        countByStatus(db, evalRunId, "pass"),
        countByStatus(db, evalRunId, "fail"),
        countReviewed(db, evalRunId),
      ]);
      const runStatus = reviewedCount >= totalSamples && totalSamples > 0 ? "complete" : "running";
      const runPatch: JsonRecord = {
        total_samples: totalSamples,
        pass_count: passCount,
        fail_count: failCount,
        status: runStatus,
      };
      if (runStatus === "complete") {
        runPatch.completed_at = nowIso;
      }
      await db.from("eval_runs").update(runPatch).eq("id", evalRunId);
    } catch (e: any) {
      console.warn(`[audit-attribution] eval_runs refresh failed: ${e.message}`);
    }
  }

  return { eval_run_id: evalRunId, sample_status: sampleStatus };
}

interface LatestAttributionRow {
  id: string;
  assigned_project_id: string | null;
  decision: string | null;
  confidence: number | null;
  attribution_source: string | null;
  evidence_tier: number | null;
}

async function lookupLatestAttribution(db: any, spanId: string): Promise<LatestAttributionRow | null> {
  const { data, error } = await db
    .from("span_attributions")
    .select(
      "id, project_id, applied_project_id, decision, confidence, attribution_source, evidence_tier, attributed_at",
    )
    .eq("span_id", spanId)
    .order("attributed_at", { ascending: false, nullsFirst: false })
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw new Error(`span_attribution_lookup_failed: ${error.message}`);
  if (!data) return null;

  return {
    id: asString(data.id),
    assigned_project_id: asUuid(data.applied_project_id || data.project_id),
    decision: asString(data.decision) || null,
    confidence: asNumber(data.confidence),
    attribution_source: asString(data.attribution_source) || null,
    evidence_tier: asNumber(data.evidence_tier),
  };
}

async function persistToLedger(
  db: any,
  req: NormalizedRequest,
  output: ReviewerOutput,
  usedModelId: string,
  guardrailViolation: boolean,
): Promise<JsonRecord> {
  const packet = req.packet;
  const spanId = asUuid(packet.span_id);
  if (!spanId) {
    throw new Error("span_id_invalid_for_ledger");
  }

  const packetJson = canonicalizeJson(req.packet_json || {}) as JsonRecord;
  const packetJsonText = JSON.stringify(packetJson);
  const packetHash = await sha256Hex(packetJsonText);

  const latest = await lookupLatestAttribution(db, spanId);
  const spanAttributionId = asUuid(packet.span_attribution_id) || asUuid(latest?.id);
  if (!spanAttributionId) {
    throw new Error("span_attribution_id_missing_for_ledger");
  }
  if (!packet.interaction_id) {
    throw new Error("interaction_id_missing_for_ledger");
  }

  const dedupeKey = await sha256Hex([
    spanAttributionId,
    usedModelId,
    PROMPT_VERSION,
    packetHash,
  ].join("|"));

  const nowIso = new Date().toISOString();
  const assignedProjectId = asUuid(packet.assigned_project_id) || latest?.assigned_project_id || null;
  const assignedDecision = asString(packet.assigned_decision) || latest?.decision || null;
  const assignedConfidence = asNumber(packet.assigned_confidence) ?? latest?.confidence ?? null;
  const attributionSource = asString(packet.attribution_source) || latest?.attribution_source || null;
  const evidenceTierRaw = asNumber(packet.assigned_evidence_tier) ?? latest?.evidence_tier ?? null;
  const evidenceTier = evidenceTierRaw === null ? null : Math.round(evidenceTierRaw);
  const spanCharStart = asNumber(packet.span_bounds.char_start);
  const spanCharEnd = asNumber(packet.span_bounds.char_end);
  const transcriptSpanHash = packet.transcript_segment ? await sha256Hex(packet.transcript_segment) : null;
  const evidenceEventIds = extractEvidenceEventIds(packet);
  const failureTags = normalizeTagList(output.failure_mode_tags);
  const missingEvidence = normalizeMissingEvidenceList(output.missing_evidence);
  const pointerQualityViolation = evidenceEventIds.length === 0 ||
    failureTags.some((tag) => tag.includes("pointer") || tag.includes("provenance")) ||
    missingEvidence.some((tag) => tag.includes("pointer") || tag.includes("provenance"));
  const topCandidateConfidence = asNumber(asRecord(output.top_candidates[0]).confidence);
  const competingMargin = topCandidateConfidence !== null && assignedConfidence !== null
    ? Number((topCandidateConfidence - assignedConfidence).toFixed(4))
    : null;

  const basePayload: JsonRecord = {
    dedupe_key: dedupeKey,
    span_attribution_id: spanAttributionId,
    span_id: spanId,
    interaction_id: packet.interaction_id,
    assigned_project_id: assignedProjectId,
    assigned_decision: assignedDecision,
    assigned_confidence: assignedConfidence,
    attribution_source: attributionSource,
    evidence_tier: evidenceTier,
    t_call_utc: parseTimestampOrNow(packet.call_at_utc),
    asof_mode: asString(packet.asof_mode) || "KNOWN_AS_OF",
    same_call_excluded: packet.same_call_excluded && !guardrailViolation,
    evidence_event_ids: evidenceEventIds,
    span_char_start: spanCharStart === null ? null : Math.round(spanCharStart),
    span_char_end: spanCharEnd === null ? null : Math.round(spanCharEnd),
    transcript_span_hash: transcriptSpanHash,
    packet_json: packetJson,
    packet_hash: packetHash,
    reviewer_provider: REVIEWER_PROVIDER,
    reviewer_model: usedModelId,
    reviewer_prompt_version: PROMPT_VERSION,
    reviewer_run_id: req.reviewer_run_id || (req.eval_sample_id ? `eval_sample:${req.eval_sample_id}` : null),
    verdict: output.verdict,
    top_candidates: output.top_candidates,
    competing_margin: competingMargin,
    failure_tags: failureTags,
    missing_evidence: missingEvidence,
    leakage_violation: guardrailViolation,
    pointer_quality_violation: pointerQualityViolation,
  };

  const insertPayload: JsonRecord = {
    ...basePayload,
    hit_count: 1,
    first_seen_at_utc: nowIso,
    last_seen_at_utc: nowIso,
  };

  const { data: inserted, error: insertErr } = await db
    .from("attribution_audit_ledger")
    .insert(insertPayload)
    .select("id, dedupe_key, hit_count, first_seen_at_utc, last_seen_at_utc")
    .maybeSingle();
  if (!insertErr && inserted) {
    return {
      persisted: true,
      dedupe_key: inserted.dedupe_key,
      ledger_id: inserted.id,
      hit_count: inserted.hit_count,
      mode: "inserted",
    };
  }

  if (insertErr?.code !== "23505") {
    throw new Error(`ledger_insert_failed: ${insertErr?.message || "unknown"}`);
  }

  const { data: existing, error: existingErr } = await db
    .from("attribution_audit_ledger")
    .select("id, hit_count")
    .eq("dedupe_key", dedupeKey)
    .maybeSingle();
  if (existingErr || !existing?.id) {
    throw new Error(`ledger_lookup_after_conflict_failed: ${existingErr?.message || "missing_row"}`);
  }
  const currentHitCount = asNumber(existing.hit_count) ?? 1;
  const nextHitCount = Math.max(1, Math.round(currentHitCount + 1));

  const { data: updated, error: updateErr } = await db
    .from("attribution_audit_ledger")
    .update({
      ...basePayload,
      hit_count: nextHitCount,
      last_seen_at_utc: nowIso,
    })
    .eq("id", existing.id)
    .select("id, dedupe_key, hit_count, first_seen_at_utc, last_seen_at_utc")
    .maybeSingle();
  if (updateErr) {
    throw new Error(`ledger_upsert_update_failed: ${updateErr.message}`);
  }

  return {
    persisted: true,
    dedupe_key: updated?.dedupe_key || dedupeKey,
    ledger_id: updated?.id || existing.id,
    hit_count: updated?.hit_count || nextHitCount,
    mode: "conflict_update",
  };
}

function shouldRetryModelFallback(errorMessage: string): boolean {
  const msg = errorMessage.toLowerCase();
  return (
    msg.includes("not_found_error") ||
    (msg.includes("model") && msg.includes("not found")) ||
    (msg.includes("404") && msg.includes("model"))
  );
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), {
      status: 405,
      headers: JSON_HEADERS,
    });
  }

  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) {
    return authErrorResponse(auth.error_code || "missing_edge_secret");
  }

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
  }
  if (packet.evidence_events.length === 0 && packet.claim_pointers.length === 0) {
    deterministicTags.push("missing_evidence_events");
    deterministicMissing.push("evidence_events");
    deterministicTags.push("provenance_context_missing");
  }
  if (leakageDetected) {
    deterministicTags.push("same_call_leakage_detected");
    deterministicMissing.push("clean_as_of_context_without_same_call_facts");
  }
  if (futureLeakageDetected) {
    deterministicTags.push("future_context_leakage_detected");
    deterministicMissing.push("as_of_project_context_observed_at<=call_at_utc");
  }

  const anthropic = new Anthropic({
    apiKey: Deno.env.get("ANTHROPIC_API_KEY") || "",
  });

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
  } catch (e: any) {
    output = {
      verdict: "INSUFFICIENT",
      top_candidates: [],
      missing_evidence: ["reviewer_llm_unavailable"],
      failure_mode_tags: ["reviewer_runtime_error"],
      rationale_anchors: [],
      notes: `LLM reviewer unavailable: ${e.message}`.slice(0, 500),
    };
  }

  output.missing_evidence = normalizeMissingEvidenceList([...output.missing_evidence, ...deterministicMissing]);
  output.failure_mode_tags = normalizeTagList([...output.failure_mode_tags, ...deterministicTags]);
  const assignedProjectUuid = asUuid(packet.assigned_project_id);
  const topCandidateProjectUuid = asUuid(output.top_candidates[0]?.project_id);

  if (
    assignedProjectUuid &&
    topCandidateProjectUuid &&
    topCandidateProjectUuid !== assignedProjectUuid
  ) {
    output.verdict = "MISMATCH";
    output.failure_mode_tags = normalizeTagList([
      ...output.failure_mode_tags,
      "top_candidate_disagrees_with_assignment",
      "assignment_disagreement",
    ]);
    if (!output.notes) {
      output.notes = "forced_mismatch_due_to_top_candidate_assignment_disagreement";
    }
  }

  if (
    output.verdict === "MATCH" &&
    (
      output.failure_mode_tags.includes("missing_project_context") ||
      output.failure_mode_tags.includes("missing_evidence_packet") ||
      output.failure_mode_tags.includes("missing_evidence_events") ||
      output.failure_mode_tags.includes("provenance_context_missing") ||
      output.failure_mode_tags.includes("pointer_or_provenance_gap")
    )
  ) {
    output.verdict = "INSUFFICIENT";
    output.notes = (output.notes
      ? `${output.notes} | forced_insufficient_due_to_missing_provenance`
      : "forced_insufficient_due_to_missing_provenance").slice(0, 500);
  }

  if (output.verdict === "MISMATCH") {
    output.failure_mode_tags = normalizeTagList([
      ...output.failure_mode_tags,
      "assignment_disagreement",
    ]);
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
      output.failure_mode_tags.includes("fake_assigned_confidence")
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

  const db = createClient(
    Deno.env.get("SUPABASE_URL") || "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
  );

  let persisted: JsonRecord = { persisted: false };
  if (!normalized.dry_run && normalized.persist) {
    const persistMeta = {
      source: auth.source || "unknown",
      function_version: FUNCTION_VERSION,
      model_id: usedModelId,
      prompt_version: PROMPT_VERSION,
      llm_parse_mode: llmParseMode,
    };

    const evalSamplePersist: JsonRecord = {
      persisted: false,
      skipped: !normalized.eval_sample_id,
    };
    if (normalized.eval_sample_id) {
      try {
        const result = await persistToEvalSample(db, normalized.eval_sample_id, output, persistMeta, usedModelId);
        evalSamplePersist.persisted = true;
        evalSamplePersist.eval_sample_id = normalized.eval_sample_id;
        evalSamplePersist.eval_run_id = result.eval_run_id;
        evalSamplePersist.sample_status = result.sample_status;
      } catch (e: any) {
        evalSamplePersist.persisted = false;
        evalSamplePersist.persistence_error = e.message;
      }
    }

    let ledgerPersist: JsonRecord;
    try {
      const structuralGuardrailViolation = leakageDetected ||
        futureLeakageDetected ||
        packet.same_call_excluded !== true ||
        asString(packet.asof_mode).toUpperCase() !== "KNOWN_AS_OF";
      ledgerPersist = await persistToLedger(
        db,
        normalized,
        output,
        usedModelId,
        structuralGuardrailViolation,
      );
    } catch (e: any) {
      ledgerPersist = {
        persisted: false,
        persistence_error: e.message,
      };
    }

    persisted = {
      persisted: evalSamplePersist.persisted === true || ledgerPersist.persisted === true,
      eval_sample: evalSamplePersist,
      ledger: ledgerPersist,
    };
  }

  // RUNTIME LINEAGE EVIDENCE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:audit-attribution", to: "table:public.eval_samples", type: "reads" },
      { from: "edge:audit-attribution", to: "table:public.span_attributions", type: "reads" },
      { from: "edge:audit-attribution", to: "table:public.attribution_audit_ledger", type: "writes" },
      { from: "edge:audit-attribution", to: "table:public.eval_samples", type: "writes" },
      { from: "edge:audit-attribution", to: "table:public.eval_runs", type: "writes" },
    ];
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: normalized.packet.span_id || normalized.packet.interaction_id,
      source_run_id: "audit-attribution:" + FUNCTION_VERSION,
      transcript_variant: "baseline",
      metadata: { edges: lineageEdges, pipeline_version: FUNCTION_VERSION },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage emission must never block the response */ }

  return new Response(
    JSON.stringify({
      ok: true,
      version: FUNCTION_VERSION,
      model_id: usedModelId,
      prompt_version: PROMPT_VERSION,
      ms: Date.now() - t0,
      reviewer_output: output,
      deterministic_checks: {
        failure_mode_tags: deterministicTags,
        missing_evidence: deterministicMissing,
      },
      llm_parse_mode: llmParseMode,
      llm_raw_preview: llmRawPreview,
      persisted,
    }),
    { status: 200, headers: JSON_HEADERS },
  );
});
