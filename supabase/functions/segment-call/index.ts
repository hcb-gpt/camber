/**
 * segment-call Edge Function v2.9.2
 * Multi-span producer: calls segment-llm, writes N conversation_spans, then chains each span to
 * context-assembly → ai-router.
 *
 * Sprint-0 invariants:
 * - Reseed rule: if ANY span_attributions exist for this interaction, do NOT resegment (409 + error_code).
 * - Fail closed: if any required downstream step fails, return 500 + error_code=chain_failed.
 * - Downstream auth uses X-Edge-Secret (never service-role bearer).
 *
 * v2.5.3: Backfill interactions.transcript_chars; clear stale G4_EMPTY_TRANSCRIPT reasons.
 * v2.6.0: Canonical transcript lookup via v_canonical_transcripts; Deepgram canonical override.
 * v2.6.1: Stopline R1 coverage invariant — backfill uncovered spans to review_queue.
 * v2.6.2: Immediate coverage_gap enqueue on per-span chain failure (best-effort).
 * v2.6.3: Per-request run_id correlation; stopline evidence pointer guard.
 *
 * v2.7.0:
 * - Per-span chain processing with bounded parallelism (SPAN_PARALLEL_CONCURRENCY env var, default 1).
 * - Eliminates timeout truncation for calls with 30+ spans.
 * - Extracted loop body into processSpanChain() with Promise.allSettled dispatch.
 * - New response field: chain.wall_clock_ms, chain.parallel_concurrency.
 *
 * v2.7.1:
 * - Fixes rerun 500: replaces hard-delete of active spans with soft-delete (is_superseded=true).
 *   Hard-delete failed when FK-constrained children (striking_signals) referenced span rows.
 *
 * v2.8.0:
 * - Proper generation tracking: new spans get segment_generation = prior_max + 1 (not hardcoded 1).
 * - Supersede metadata: sets superseded_at + superseded_by_action_id on old spans for audit trail.
 * - Ensures rerun of same interaction_id produces incrementing generations with no FK errors.
 *
 * v2.9.2:
 * - Tightens reseed guard scope: block resegment when any attribution exists on any span generation
 *   for the interaction (including superseded spans), preventing duplicate span trees on reruns.
 *
 * Auth (internal gate; verify_jwt=false):
 * - X-Edge-Secret == EDGE_SHARED_SECRET, OR
 * - JWT + ALLOWED_EMAILS verified via auth.getUser() (debug path)
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { checkReseedGuard } from "./reseed_guard.ts";

const SEGMENT_CALL_VERSION = "v2.9.2";
const MAX_SEGMENT_CHARS_HARD_LIMIT = 3000;
const MAX_HOOK_NON2XX_DIAGNOSTICS = 3;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SEGMENT_LLM_URL = `${SUPABASE_URL}/functions/v1/segment-llm`;
const CONTEXT_ASSEMBLY_URL = `${SUPABASE_URL}/functions/v1/context-assembly`;
const AI_ROUTER_URL = `${SUPABASE_URL}/functions/v1/ai-router`;
const STRIKING_DETECT_URL = `${SUPABASE_URL}/functions/v1/striking-detect`;
const JOURNAL_EXTRACT_URL = `${SUPABASE_URL}/functions/v1/journal-extract`;
const GENERATE_SUMMARY_URL = `${SUPABASE_URL}/functions/v1/generate-summary`;
const EVIDENCE_ASSEMBLER_URL = `${SUPABASE_URL}/functions/v1/evidence-assembler`;
const DECISION_AUDITOR_URL = `${SUPABASE_URL}/functions/v1/decision-auditor`;

type SegmentFromLLM = {
  span_index: number;
  char_start: number;
  char_end: number;
  boundary_reason: string;
  confidence: number;
  boundary_quote: string | null;
};

type SpanChainStatus = {
  span_id: string;
  span_index: number;
  context_assembly_status: number | null;
  ai_router_status: number | null;
  error_code: string | null;
  error_detail: string | null;
  // v2.4.0: async post-attribution hooks
  striking_detect_fired: boolean;
  journal_extract_fired: boolean;
  // v2.6.0: evidence assembler + decision auditor
  evidence_assembler_status?: number | null;
  evidence_assembler_error?: string | null;
  decision_auditor_status?: number | null;
  decision_auditor_error?: string | null;
  assembler_triggered?: boolean;
  auditor_triggered?: boolean;
};

const jsonHeaders = { "Content-Type": "application/json" };

type TranscriptSanitizeResult = {
  text: string;
  replaced: number;
};

function sanitizeTranscriptForPipeline(text: string): TranscriptSanitizeResult {
  let replaced = 0;
  // deno-lint-ignore no-control-regex -- intentional: scrub control chars before JSON packaging/prompting
  const sanitized = String(text || "").replace(/[\x00-\x1F\x7F]/g, () => {
    replaced += 1;
    return " ";
  });
  return { text: sanitized, replaced };
}

function normalizeReasonCodes(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((r) => String(r || "").trim()).filter(Boolean);
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function deterministicSegmentsForLength(
  transcriptLength: number,
  maxSegmentChars: number,
  boundaryReason: string,
): SegmentFromLLM[] {
  if (transcriptLength <= 0) {
    return [{
      span_index: 0,
      char_start: 0,
      char_end: 0,
      boundary_reason: boundaryReason,
      confidence: 1,
      boundary_quote: null,
    }];
  }

  const chunkCount = Math.max(1, Math.ceil(transcriptLength / Math.max(1, maxSegmentChars)));
  const segments: SegmentFromLLM[] = [];
  for (let i = 0; i < chunkCount; i++) {
    const charStart = Math.floor((transcriptLength * i) / chunkCount);
    const charEnd = Math.floor((transcriptLength * (i + 1)) / chunkCount);
    segments.push({
      span_index: i,
      char_start: charStart,
      char_end: charEnd,
      boundary_reason: boundaryReason,
      confidence: 0.5,
      boundary_quote: null,
    });
  }
  return segments;
}

function enforceMaxSegmentChars(
  inputSegments: SegmentFromLLM[],
  maxSegmentChars: number,
  warnings: string[],
): SegmentFromLLM[] {
  const rebuilt: SegmentFromLLM[] = [];

  for (const seg of inputSegments) {
    const segLen = Math.max(0, seg.char_end - seg.char_start);
    if (segLen <= maxSegmentChars || segLen === 0) {
      rebuilt.push(seg);
      continue;
    }

    const chunkCount = Math.ceil(segLen / maxSegmentChars);
    warnings.push(`segment_call_split_oversize_${seg.span_index}_into_${chunkCount}`);
    for (let i = 0; i < chunkCount; i++) {
      const charStart = seg.char_start + Math.floor((segLen * i) / chunkCount);
      const charEnd = seg.char_start + Math.floor((segLen * (i + 1)) / chunkCount);
      rebuilt.push({
        span_index: 0,
        char_start: charStart,
        char_end: charEnd,
        boundary_reason: `${seg.boundary_reason}_segment_call_split`,
        confidence: seg.confidence,
        boundary_quote: i === 0 ? seg.boundary_quote : null,
      });
    }
  }

  return rebuilt.map((seg, idx) => ({ ...seg, span_index: idx }));
}

async function logDiagnostic(
  message: string,
  metadata: Record<string, unknown>,
  logLevel = "error",
): Promise<void> {
  try {
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceRoleKey) return;
    const sb = createClient(SUPABASE_URL, serviceRoleKey);
    await sb.from("diagnostic_logs").insert({
      function_name: "segment-call",
      function_version: SEGMENT_CALL_VERSION,
      log_level: logLevel,
      message,
      metadata,
    });
  } catch (e) {
    console.warn(`[segment-call] diagnostic_logs insert failed: ${(e as Error)?.message || e}`);
  }
}

type CoverageSpanRow = {
  span_id: string;
  interaction_id: string;
  span_index: number | null;
  transcript_segment: string | null;
};

type CoverageInvariantResult = {
  before_count: number;
  after_count: number;
  backfilled_count: number;
  backfilled_span_ids: string[];
  error: string | null;
};

type CoverageGapEnqueueInput = CoverageSpanRow & {
  error_code: string;
  error_detail: string | null;
  context_assembly_status: number | null;
  ai_router_status: number | null;
};

type CoverageGapEnqueueResult = {
  queued: boolean;
  duplicate: boolean;
  legacy_mode: boolean;
  error: string | null;
};

function isReviewQueueCompatColumnMissing(message: string): boolean {
  const text = String(message || "").toLowerCase();
  return text.includes("does not exist") &&
    (
      text.includes("module") ||
      text.includes("dedupe_key") ||
      text.includes("reason_codes")
    );
}

function isDuplicateKeyError(error: any): boolean {
  const code = String(error?.code || "");
  const message = String(error?.message || "").toLowerCase();
  const details = String(error?.details || "").toLowerCase();
  return code === "23505" || message.includes("duplicate key") || details.includes("already exists");
}

async function enqueueCoverageGapReview(
  db: any,
  input: CoverageGapEnqueueInput,
): Promise<CoverageGapEnqueueResult> {
  try {
    const nowIso = new Date().toISOString();
    const contextPayload = {
      source: "segment-call",
      stopline: "r1_stopline_zero_dropped_spans",
      reason_codes: ["coverage_gap"],
      interaction_id: input.interaction_id,
      span_id: input.span_id,
      span_index: input.span_index,
      error_code: input.error_code,
      error_detail: input.error_detail,
      context_assembly_status: input.context_assembly_status,
      ai_router_status: input.ai_router_status,
      transcript_snippet: (input.transcript_segment || "").slice(0, 600),
      detected_at_utc: nowIso,
    };

    const modernPayload = {
      span_id: input.span_id,
      interaction_id: input.interaction_id,
      status: "pending",
      module: "attribution",
      dedupe_key: `coverage_gap:${input.span_id}`,
      reason_codes: ["coverage_gap"],
      reasons: ["coverage_gap"],
      context_payload: contextPayload,
    };

    let { error } = await db
      .from("review_queue")
      .insert(modernPayload);

    if (!error) {
      return { queued: true, duplicate: false, legacy_mode: false, error: null };
    }

    if (isDuplicateKeyError(error)) {
      return { queued: false, duplicate: true, legacy_mode: false, error: null };
    }

    if (isReviewQueueCompatColumnMissing(error.message || "")) {
      const legacyPayload = {
        span_id: input.span_id,
        interaction_id: input.interaction_id,
        status: "pending",
        reasons: ["coverage_gap"],
        context_payload: contextPayload,
      };

      const legacyInsert = await db
        .from("review_queue")
        .insert(legacyPayload);
      error = legacyInsert.error ?? null;

      if (!error) {
        return { queued: true, duplicate: false, legacy_mode: true, error: null };
      }
      if (isDuplicateKeyError(error)) {
        return { queued: false, duplicate: true, legacy_mode: true, error: null };
      }
    }

    return {
      queued: false,
      duplicate: false,
      legacy_mode: false,
      error: error?.message || "coverage_gap_enqueue_failed_unknown",
    };
  } catch (error: any) {
    return {
      queued: false,
      duplicate: false,
      legacy_mode: false,
      error: `coverage_gap_enqueue_exception:${error?.message || "unknown"}`,
    };
  }
}

async function listUncoveredActiveSpans(
  db: any,
  interactionId: string,
): Promise<{ rows: CoverageSpanRow[]; error: string | null }> {
  const { data: activeSpans, error: activeErr } = await db
    .from("conversation_spans")
    .select("id, interaction_id, span_index, transcript_segment")
    .eq("interaction_id", interactionId)
    .eq("is_superseded", false);

  if (activeErr) return { rows: [], error: `active_spans_query_failed:${activeErr.message}` };
  if (!Array.isArray(activeSpans) || activeSpans.length === 0) return { rows: [], error: null };

  const spanIds = activeSpans.map((s: any) => s.id).filter(Boolean);
  if (spanIds.length === 0) return { rows: [], error: null };

  const { data: attributionRows, error: attrErr } = await db
    .from("span_attributions")
    .select("span_id")
    .in("span_id", spanIds);
  if (attrErr) return { rows: [], error: `span_attributions_query_failed:${attrErr.message}` };

  const { data: reviewRows, error: reviewErr } = await db
    .from("review_queue")
    .select("span_id")
    .in("span_id", spanIds)
    .eq("status", "pending");
  if (reviewErr) return { rows: [], error: `review_queue_query_failed:${reviewErr.message}` };

  const attributed = new Set((attributionRows || []).map((r: any) => String(r.span_id)));
  const inReview = new Set((reviewRows || []).map((r: any) => String(r.span_id)));

  const uncovered = (activeSpans || [])
    .filter((s: any) => !attributed.has(String(s.id)) && !inReview.has(String(s.id)))
    .map((s: any) => ({
      span_id: String(s.id),
      interaction_id: String(s.interaction_id ?? interactionId),
      span_index: s.span_index == null ? null : Number(s.span_index),
      transcript_segment: typeof s.transcript_segment === "string" ? s.transcript_segment : null,
    }));

  return { rows: uncovered, error: null };
}

async function enforceCoverageInvariant(
  db: any,
  interactionId: string,
): Promise<CoverageInvariantResult> {
  const before = await listUncoveredActiveSpans(db, interactionId);
  if (before.error) {
    return {
      before_count: 0,
      after_count: 0,
      backfilled_count: 0,
      backfilled_span_ids: [],
      error: before.error,
    };
  }

  if (before.rows.length > 0) {
    const nowIso = new Date().toISOString();
    const baseContextPayload = (row: CoverageSpanRow) => ({
      source: "segment-call",
      stopline: "r1_stopline_zero_dropped_spans",
      reason_codes: ["coverage_gap"],
      interaction_id: row.interaction_id,
      span_id: row.span_id,
      span_index: row.span_index,
      transcript_snippet: (row.transcript_segment || "").slice(0, 600),
      detected_at_utc: nowIso,
    });

    const payload = before.rows.map((row) => ({
      span_id: row.span_id,
      interaction_id: row.interaction_id,
      status: "pending",
      module: "attribution",
      dedupe_key: `coverage_gap:${row.span_id}`,
      reason_codes: ["coverage_gap"],
      reasons: ["coverage_gap"],
      context_payload: baseContextPayload(row),
    }));

    let { error: backfillErr } = await db
      .from("review_queue")
      .upsert(payload, { onConflict: "span_id" });

    if (backfillErr) {
      const message = (backfillErr.message || "").toLowerCase();
      const missingCompatColumns = message.includes("does not exist") &&
        (
          message.includes("module") ||
          message.includes("dedupe_key") ||
          message.includes("reason_codes")
        );

      if (missingCompatColumns) {
        const legacyPayload = before.rows.map((row) => ({
          span_id: row.span_id,
          interaction_id: row.interaction_id,
          status: "pending",
          reasons: ["coverage_gap"],
          context_payload: baseContextPayload(row),
        }));

        const legacyUpsert = await db
          .from("review_queue")
          .upsert(legacyPayload, { onConflict: "span_id" });
        backfillErr = legacyUpsert.error ?? null;
      }
    }

    if (backfillErr) {
      return {
        before_count: before.rows.length,
        after_count: before.rows.length,
        backfilled_count: 0,
        backfilled_span_ids: before.rows.map((r) => r.span_id),
        error: `coverage_backfill_failed:${backfillErr.message}`,
      };
    }
  }

  const after = await listUncoveredActiveSpans(db, interactionId);
  if (after.error) {
    return {
      before_count: before.rows.length,
      after_count: before.rows.length,
      backfilled_count: 0,
      backfilled_span_ids: before.rows.map((r) => r.span_id),
      error: after.error,
    };
  }

  return {
    before_count: before.rows.length,
    after_count: after.rows.length,
    backfilled_count: Math.max(0, before.rows.length - after.rows.length),
    backfilled_span_ids: before.rows.map((r) => r.span_id),
    error: null,
  };
}

// v2.6.0: Evidence assembler + decision auditor feature flag
const ASSEMBLER_MODE = Deno.env.get("ASSEMBLER_MODE") || "off"; // "off" | "shadow" | "live"

// v2.9.0: Skip-attribution mode — segment + extract claims without project attribution.
// Keeps: segmentation, journal-extract (claims), striking-detect, generate-summary.
// Skips: context-assembly, ai-router, evidence-assembler, decision-auditor, coverage invariant.
// Use for GT training set builds where human grading replaces AI attribution.
const SKIP_ATTRIBUTION_DEFAULT = (() => {
  const raw = (Deno.env.get("SKIP_ATTRIBUTION") || "").trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
})();

function shouldRunAssembler(ctx: any): { run: boolean; reasons: string[] } {
  const reasons: string[] = [];
  const candidates = ctx.candidates || [];
  const contact = ctx.contact;

  // Gate 1: Floater/drifter/unknown
  if (["floater", "drifter", "unknown"].includes(contact?.fanout_class || "")) {
    reasons.push("floater_drifter_unknown");
  }
  // Gate 2: No strong alias match
  const hasStrong = candidates.some((c: any) =>
    c.evidence?.alias_matches?.some((m: any) =>
      ["exact_project_name", "alias", "address_fragment", "client_name"].includes(m.match_type)
    )
  );
  if (!hasStrong) reasons.push("no_strong_alias");

  // Gate 3: Top-2 tie
  const strengths = candidates.map((c: any) => c.evidence?.source_strength || 0).sort((a: number, b: number) => b - a);
  if (strengths.length >= 2 && Math.abs(strengths[0] - strengths[1]) < 0.10) {
    reasons.push("candidate_tie");
  }
  // Gate 4: Collision-risk alias (common-word)
  if (candidates.some((c: any) => c.evidence?.common_word_alias_demoted)) {
    reasons.push("collision_risk_alias");
  }
  // Gate 5: Null contact
  if (!contact?.contact_id) reasons.push("null_contact");

  return { run: reasons.length > 0, reasons };
}

function shouldRunAuditor(decision: string, confidence: number): boolean {
  return decision === "assign" && confidence < 0.85;
}

// v2.7.0: Parallel span chain processing
// Default 1 = sequential (safe rollback). Set to 5 in prod for parallelism.
const SPAN_PARALLEL_CONCURRENCY = Math.max(
  1,
  parseInt(Deno.env.get("SPAN_PARALLEL_CONCURRENCY") || "1", 10) || 1,
);

/** Sliding-window concurrency limiter (p-limit pattern, zero deps). */
function createConcurrencyLimiter(concurrency: number) {
  let active = 0;
  const queue: Array<() => void> = [];
  return async function <T>(fn: () => Promise<T>): Promise<T> {
    if (active >= concurrency) {
      await new Promise<void>((resolve) => queue.push(resolve));
    }
    active++;
    try {
      return await fn();
    } finally {
      active--;
      if (queue.length > 0) queue.shift()!();
    }
  };
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();
  const run_id = `seg_${t0}_${Math.random().toString(36).slice(2, 8)}`;

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only", run_id }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  try {
    // ============================================================
    // INTERNAL AUTH GATE (verify_jwt: false - auth handled here)
    // ============================================================
    const edgeSecretHeader = req.headers.get("X-Edge-Secret");
    const expectedSecret = Deno.env.get("EDGE_SHARED_SECRET");
    const authHeader = req.headers.get("Authorization");

    let body: any;
    try {
      body = await req.json();
    } catch {
      await logDiagnostic("INPUT_INVALID", { reason: "invalid_json_body" }, "warning");
      return new Response(
        JSON.stringify({
          ok: false,
          error: "invalid_json",
          error_code: "bad_request",
          run_id,
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 400, headers: jsonHeaders },
      );
    }

    const hasValidEdgeSecret = expectedSecret &&
      edgeSecretHeader === expectedSecret;

    let hasValidJwt = false;
    if (!hasValidEdgeSecret && authHeader?.startsWith("Bearer ")) {
      const anonClient = createClient(
        SUPABASE_URL,
        Deno.env.get("SUPABASE_ANON_KEY")!,
        { global: { headers: { Authorization: authHeader } } },
      );
      const { data: { user }, error: authErr } = await anonClient.auth.getUser();
      if (!authErr && user?.email) {
        const allowedEmails = (Deno.env.get("ALLOWED_EMAILS") || "")
          .split(",")
          .map((e) => e.trim().toLowerCase())
          .filter(Boolean);
        hasValidJwt = allowedEmails.includes(user.email.toLowerCase());
      }
    }

    if (!hasValidEdgeSecret && !hasValidJwt) {
      console.error(
        `[segment-call] AUTH_FAILED run_id=${run_id} edge_secret_present=${
          Boolean(edgeSecretHeader)
        } auth_header_present=${Boolean(authHeader)}`,
      );
      await logDiagnostic("AUTH_FAILED", {
        reason: "edge_secret_or_allowed_jwt_required",
        edge_secret_present: Boolean(edgeSecretHeader),
        auth_header_present: Boolean(authHeader),
        allowed_jwt: hasValidJwt,
      });
      return new Response(
        JSON.stringify({
          ok: false,
          error: "unauthorized",
          error_code: "auth_failed",
          run_id,
          hint: "Requires X-Edge-Secret matching EDGE_SHARED_SECRET OR JWT with allowed email",
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 401, headers: jsonHeaders },
      );
    }

    const {
      interaction_id,
      transcript,
      channel: requested_channel = null,
      dry_run = false,
      skip_attribution = SKIP_ATTRIBUTION_DEFAULT,
      max_segments = 10,
      min_segment_chars = 200,
    } = body;

    if (!interaction_id) {
      await logDiagnostic("INPUT_INVALID", { reason: "missing_interaction_id" }, "warning");
      return new Response(
        JSON.stringify({
          ok: false,
          error: "missing_interaction_id",
          error_code: "bad_request",
          run_id,
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 400, headers: jsonHeaders },
      );
    }

    const requestedChannelNorm = typeof requested_channel === "string" ? requested_channel.trim().toLowerCase() : "";
    const inferredSmsChannel = String(interaction_id).startsWith("sms_thread_") ||
      String(interaction_id).startsWith("beside_sms_");
    const segmentationChannel = requestedChannelNorm || (inferredSmsChannel ? "sms_thread" : "call");

    const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET");
    if (!edgeSecret) {
      await logDiagnostic("AUTH_FAILED", {
        reason: "edge_shared_secret_missing",
      });
      return new Response(
        JSON.stringify({
          ok: false,
          error: "config_error",
          error_code: "config_missing",
          run_id,
          hint: "EDGE_SHARED_SECRET not set",
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    const db = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let spans_written = false;
    let spans_write_ok = false;
    let parent_interaction_sync_applied = false;
    let parent_interaction_sync_error: string | null = null;
    let parent_interaction_transcript_chars: number | null = null;

    // ============================================================
    // 1) FETCH TRANSCRIPT
    // ============================================================
    let spanTranscript: string | null = typeof transcript === "string" ? transcript : null;
    let transcriptSource: string | null = null;
    const canonicalWarnings: string[] = [];

    // --- Canonical transcript view lookup (v2.6.0) ---
    const { data: canonicalRow } = await db
      .from("v_canonical_transcripts")
      .select("transcript, transcript_source")
      .eq("interaction_id", interaction_id)
      .maybeSingle();

    if (canonicalRow?.transcript && canonicalRow.transcript_source?.startsWith("deepgram/")) {
      // Deepgram canonical overrides request_body
      if (spanTranscript && spanTranscript !== canonicalRow.transcript) {
        canonicalWarnings.push("request_body_transcript_overridden_by_deepgram_canonical");
      }
      spanTranscript = canonicalRow.transcript;
      transcriptSource = canonicalRow.transcript_source;
    } else if (!spanTranscript && canonicalRow?.transcript) {
      // Non-deepgram canonical used as fallback
      spanTranscript = canonicalRow.transcript;
      transcriptSource = canonicalRow.transcript_source;
    } else if (spanTranscript) {
      transcriptSource = "request_body";
    }

    if (!spanTranscript) {
      const { data: callsRaw, error: fetchErr } = await db
        .from("calls_raw")
        .select("transcript")
        .eq("interaction_id", interaction_id)
        .single();

      if (fetchErr || !callsRaw?.transcript) {
        await logDiagnostic("INPUT_INVALID", {
          reason: "transcript_not_found",
          interaction_id,
        }, "warning");
        return new Response(
          JSON.stringify({
            ok: false,
            error: "transcript_not_found",
            error_code: "no_transcript",
            interaction_id,
            version: SEGMENT_CALL_VERSION,
          }),
          { status: 400, headers: jsonHeaders },
        );
      }

      spanTranscript = callsRaw.transcript;
      transcriptSource = "calls_raw";
    }

    const transcriptSanitize = sanitizeTranscriptForPipeline(spanTranscript || "");
    spanTranscript = transcriptSanitize.text;
    const transcriptControlCharsSanitized = transcriptSanitize.replaced;

    // ============================================================
    // 1b) STOPLINE: ENSURE CALL EVIDENCE EVENT EXISTS
    // ============================================================
    if (!dry_run) {
      const { data: callsRawMeta } = await db
        .from("calls_raw")
        .select("id, event_at_utc, transcript")
        .eq("interaction_id", interaction_id)
        .maybeSingle();

      const callEvidenceOccurredAt = callsRawMeta?.event_at_utc || new Date().toISOString();
      const callEvidencePayloadRef = callsRawMeta?.id
        ? `calls_raw:${callsRawMeta.id}`
        : `call_interaction:${interaction_id}:baseline`;
      const callEvidenceIntegrityHash = await sha256Hex(
        `${interaction_id}|baseline|${spanTranscript || callsRawMeta?.transcript || ""}`,
      );

      const { error: callEvidenceErr } = await db.from("evidence_events").upsert({
        source_type: "call",
        source_id: interaction_id,
        source_run_id: `segment-call:${SEGMENT_CALL_VERSION}`,
        transcript_variant: "baseline",
        occurred_at_utc: callEvidenceOccurredAt,
        payload_ref: callEvidencePayloadRef,
        integrity_hash: callEvidenceIntegrityHash,
        metadata: {
          ensured_by: "segment-call",
          ensured_version: SEGMENT_CALL_VERSION,
          guard: "call_evidence_coverage_stopline",
          is_shadow: String(interaction_id || "").startsWith("cll_SHADOW"),
        },
      }, {
        onConflict: "source_type,source_id,transcript_variant",
        ignoreDuplicates: true,
      });

      if (callEvidenceErr) {
        await logDiagnostic("DB_WRITE_FAILED", {
          reason: "call_evidence_upsert_failed",
          interaction_id,
          detail: callEvidenceErr.message,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            error: "call_evidence_write_failed",
            error_code: "call_evidence_write_failed",
            detail: callEvidenceErr.message,
            interaction_id,
            version: SEGMENT_CALL_VERSION,
          }),
          { status: 500, headers: jsonHeaders },
        );
      }
    }

    // ============================================================
    // 2) RESEED RULE (409 IF ANY ATTRIBUTIONS EXIST ON ANY SPANS FOR INTERACTION)
    // ============================================================
    const reseedGuard = await checkReseedGuard(db, interaction_id);
    if (reseedGuard.error) {
      const [reason, detail] = reseedGuard.error.split(":", 2);
      await logDiagnostic("DB_WRITE_FAILED", {
        reason: reason || "reseed_guard_query_failed",
        interaction_id,
        detail: detail || reseedGuard.error,
      });
      return new Response(
        JSON.stringify({
          ok: false,
          error: "db_error",
          error_code: "db_error",
          detail: reseedGuard.error,
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }
    if (reseedGuard.blocked) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: "already_attributed",
          error_code: "already_attributed",
          interaction_id,
          version: SEGMENT_CALL_VERSION,
        }),
        { status: 409, headers: jsonHeaders },
      );
    }

    // ============================================================
    // 3) CALL segment-llm FOR SEGMENTATION (FAIL-SAFE FALLBACK)
    // ============================================================
    let segments: SegmentFromLLM[] = [];
    let segmenterVersion = "fallback_trivial_v1";
    const segmenterWarnings: string[] = [];
    segmenterWarnings.push(...canonicalWarnings);
    if (!requestedChannelNorm && inferredSmsChannel) {
      segmenterWarnings.push("channel_inferred_sms_thread_from_interaction_id");
    }
    if (transcriptControlCharsSanitized > 0) {
      segmenterWarnings.push(`transcript_control_chars_sanitized_${transcriptControlCharsSanitized}`);
    }

    // ============================================================
    // 3a) BACKFILL PARENT INTERACTION TRANSCRIPT METADATA
    // Keeps interactions.transcript_chars/review_reasons in sync when
    // segment-call receives transcript later than process-call.
    // ============================================================
    if (!dry_run && spanTranscript.length > 0) {
      const transcriptChars = spanTranscript.length;
      parent_interaction_transcript_chars = transcriptChars;

      const { data: interactionRow, error: interactionFetchErr } = await db
        .from("interactions")
        .select("transcript_chars, review_reasons, needs_review")
        .eq("interaction_id", interaction_id)
        .maybeSingle();

      if (interactionFetchErr) {
        parent_interaction_sync_error = interactionFetchErr.message;
        segmenterWarnings.push("interaction_parent_sync_fetch_failed");
        await logDiagnostic("DB_WRITE_FAILED", {
          reason: "interaction_parent_sync_fetch_failed",
          interaction_id,
          detail: interactionFetchErr.message,
        }, "warning");
      } else if (interactionRow) {
        const currentChars = Number(interactionRow.transcript_chars || 0);
        const existingReasons = normalizeReasonCodes(interactionRow.review_reasons);
        const cleanedReasons = existingReasons.filter((r) =>
          r !== "G4_EMPTY_TRANSCRIPT" && r !== "terminal_empty_transcript"
        );
        const removedEmptyTranscriptReason = existingReasons.length !== cleanedReasons.length;
        const nextTranscriptChars = Math.max(currentChars, transcriptChars);
        const shouldSync = nextTranscriptChars > currentChars || removedEmptyTranscriptReason;

        if (shouldSync) {
          const updatePayload: Record<string, unknown> = {
            transcript_chars: nextTranscriptChars,
          };
          if (removedEmptyTranscriptReason) {
            updatePayload.review_reasons = cleanedReasons;
            if ((interactionRow.needs_review === true) && cleanedReasons.length === 0) {
              updatePayload.needs_review = false;
            }
          }

          const { error: interactionUpdateErr } = await db
            .from("interactions")
            .update(updatePayload)
            .eq("interaction_id", interaction_id);

          if (interactionUpdateErr) {
            parent_interaction_sync_error = interactionUpdateErr.message;
            segmenterWarnings.push("interaction_parent_sync_update_failed");
            await logDiagnostic("DB_WRITE_FAILED", {
              reason: "interaction_parent_sync_update_failed",
              interaction_id,
              detail: interactionUpdateErr.message,
            }, "warning");
          } else {
            parent_interaction_sync_applied = true;
          }
        }
      }
    }

    try {
      const llmResp = await fetch(SEGMENT_LLM_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
          // No Authorization header - segment-llm uses X-Edge-Secret only
        },
        body: JSON.stringify({
          interaction_id,
          channel: segmentationChannel,
          transcript: spanTranscript,
          source: "segment-call",
          max_segments,
          min_segment_chars,
          max_segment_chars: MAX_SEGMENT_CHARS_HARD_LIMIT,
        }),
      });

      if (!llmResp.ok) {
        segmenterWarnings.push(`segment_llm_http_${llmResp.status}`);
        segments = deterministicSegmentsForLength(
          spanTranscript.length,
          MAX_SEGMENT_CHARS_HARD_LIMIT,
          "fallback_segment_llm_http_error",
        );
      } else {
        const llmData = await llmResp.json();
        if (llmData?.ok && Array.isArray(llmData.segments) && llmData.segments.length > 0) {
          segments = llmData.segments;
          segmenterVersion = llmData.segmenter_version || "segment-llm_v1.0.0";
          if (Array.isArray(llmData.warnings)) segmenterWarnings.push(...llmData.warnings);
        } else {
          segmenterWarnings.push("segment_llm_invalid_response");
          segments = deterministicSegmentsForLength(
            spanTranscript.length,
            MAX_SEGMENT_CHARS_HARD_LIMIT,
            "fallback_segment_llm_invalid",
          );
        }
      }
    } catch (e: any) {
      segmenterWarnings.push(`segment_llm_fetch_error:${e?.message || "unknown"}`);
      segments = deterministicSegmentsForLength(
        spanTranscript.length,
        MAX_SEGMENT_CHARS_HARD_LIMIT,
        "fallback_segment_llm_fetch_error",
      );
    }
    segments = enforceMaxSegmentChars(segments, MAX_SEGMENT_CHARS_HARD_LIMIT, segmenterWarnings);

    // ============================================================
    // 4) REBUILD SPANS (SAFE: NO ATTRIBUTIONS ON ACTIVE SPANS)
    //    v2.8.0: proper generation tracking + supersede metadata
    // ============================================================
    const now = new Date().toISOString();
    const supersedeActionId = crypto.randomUUID();
    let nextGeneration = 1;

    if (existingSpans && existingSpans.length > 0) {
      // Query max generation for this interaction
      const { data: genRow } = await db
        .from("conversation_spans")
        .select("segment_generation")
        .eq("interaction_id", interaction_id)
        .order("segment_generation", { ascending: false })
        .limit(1)
        .maybeSingle();

      const priorMax = genRow?.segment_generation ?? 0;
      nextGeneration = priorMax + 1;

      // Soft-supersede: mark active spans with timestamp + action_id for audit trail.
      const { error: supersedeErr } = await db
        .from("conversation_spans")
        .update({
          is_superseded: true,
          superseded_at: now,
          superseded_by_action_id: supersedeActionId,
        })
        .eq("interaction_id", interaction_id)
        .eq("is_superseded", false);

      if (supersedeErr) {
        return new Response(
          JSON.stringify({
            ok: false,
            error: "span_supersede_failed",
            error_code: "db_error",
            detail: supersedeErr.message,
            version: SEGMENT_CALL_VERSION,
          }),
          { status: 500, headers: jsonHeaders },
        );
      }
    }

    const isDeterministicFallback = segmenterWarnings.includes("deterministic_fallback_applied");
    const spanRowsWithMetadata = segments.map((seg) => {
      const segmentText = spanTranscript!.slice(seg.char_start, seg.char_end);
      const wordCount = segmentText.split(/\s+/).filter(Boolean).length;
      const metadata: Record<string, any> = {
        confidence: seg.confidence,
        boundary_quote: seg.boundary_quote,
        transcript_source: transcriptSource,
      };
      // Mark segments created by deterministic fallback
      if (isDeterministicFallback) {
        metadata.fallback = true;
      }
      return {
        interaction_id,
        span_index: seg.span_index,
        char_start: seg.char_start,
        char_end: seg.char_end,
        transcript_segment: segmentText,
        word_count: wordCount,
        segmenter_version: segmenterVersion,
        segment_reason: seg.boundary_reason,
        segment_metadata: metadata,
        is_superseded: false,
        segment_generation: nextGeneration,
        created_at: now,
      };
    });

    spans_written = true;

    // insert attempt #1 (with segment_metadata)
    let insertedSpans: { id: string; span_index: number }[] = [];
    const ins1 = await db
      .from("conversation_spans")
      .insert(spanRowsWithMetadata)
      .select("id, span_index");

    if (ins1.error) {
      const msg = (ins1.error.message || "").toLowerCase();
      const missingMetaCol = msg.includes("segment_metadata") && msg.includes("does not exist");
      if (!missingMetaCol) {
        await logDiagnostic("STOPLINE_SPAN_WRITE_BLOCKED", {
          reason: "conversation_spans_insert_failed",
          interaction_id,
          run_id,
          detail: ins1.error.message,
          code: ins1.error.code,
          stopline: "call_evidence_coverage",
        }, "warning");
        return new Response(
          JSON.stringify({
            ok: false,
            error: "span_creation_failed",
            error_code: "db_error",
            detail: ins1.error.message,
            run_id,
            version: SEGMENT_CALL_VERSION,
            spans_written,
            spans_write_ok,
          }),
          { status: 500, headers: jsonHeaders },
        );
      }

      // retry without segment_metadata (migration is optional)
      segmenterWarnings.push("segment_metadata_column_missing");
      const rowsNoMeta = spanRowsWithMetadata.map((r: any) => {
        const { segment_metadata: _omit, ...rest } = r;
        return rest;
      });

      const ins2 = await db
        .from("conversation_spans")
        .insert(rowsNoMeta)
        .select("id, span_index");

      if (ins2.error) {
        await logDiagnostic("STOPLINE_SPAN_WRITE_BLOCKED", {
          reason: "conversation_spans_insert_failed",
          interaction_id,
          run_id,
          detail: ins2.error.message,
          code: ins2.error.code,
          stopline: "call_evidence_coverage",
        }, "warning");
        return new Response(
          JSON.stringify({
            ok: false,
            error: "span_creation_failed",
            error_code: "db_error",
            detail: ins2.error.message,
            run_id,
            version: SEGMENT_CALL_VERSION,
            spans_written,
            spans_write_ok,
          }),
          { status: 500, headers: jsonHeaders },
        );
      }

      insertedSpans = (ins2.data || []) as any;
    } else {
      insertedSpans = (ins1.data || []) as any;
    }

    insertedSpans.sort((a, b) => a.span_index - b.span_index);

    // Keep span transcript snippets available for per-span failure queue fallbacks.
    const transcriptBySpanIndex = new Map<number, string>();
    for (const row of spanRowsWithMetadata) {
      transcriptBySpanIndex.set(row.span_index, row.transcript_segment);
    }

    const spanIds = insertedSpans.map((s) => s.id);
    const spanCount = insertedSpans.length;

    spans_write_ok = true;

    // ============================================================
    // 5) PER-SPAN CHAIN: context-assembly → ai-router
    //    v2.7.0: bounded parallel dispatch (SPAN_PARALLEL_CONCURRENCY)
    // ============================================================
    /** Process a single span through the full chain. Returns status; never throws. */
    const processSpanChain = async (
      span: { id: string; span_index: number },
    ): Promise<SpanChainStatus> => {
      // Per-span diagnostic budget (safe for concurrent execution)
      let hookNon2xxDiagnostics = 0;
      const tryConsumeHookNon2xxDiagnosticBudget = (): boolean => {
        if (hookNon2xxDiagnostics >= MAX_HOOK_NON2XX_DIAGNOSTICS) return false;
        hookNon2xxDiagnostics += 1;
        return true;
      };

      const status: SpanChainStatus = {
        span_id: span.id,
        span_index: span.span_index,
        context_assembly_status: null,
        ai_router_status: null,
        error_code: null,
        error_detail: null,
        striking_detect_fired: false,
        journal_extract_fired: false,
      };

      const enqueueCoverageGapForFailure = async () => {
        if (!status.error_code) return;
        const enqueueResult = await enqueueCoverageGapReview(db, {
          span_id: status.span_id,
          interaction_id,
          span_index: status.span_index,
          transcript_segment: transcriptBySpanIndex.get(status.span_index) ?? null,
          error_code: status.error_code,
          error_detail: status.error_detail,
          context_assembly_status: status.context_assembly_status,
          ai_router_status: status.ai_router_status,
        });

        if (enqueueResult.error) {
          console.warn(
            `[segment-call] coverage-gap enqueue failed for span=${status.span_id}: ${enqueueResult.error}`,
          );
          await logDiagnostic("STOPLINE_COVERAGE_GAP_ENQUEUE_FAILED", {
            interaction_id,
            stopline: "r1_stopline_zero_dropped_spans",
            span_id: status.span_id,
            span_index: status.span_index,
            error_code: status.error_code,
            error_detail: status.error_detail,
            context_assembly_status: status.context_assembly_status,
            ai_router_status: status.ai_router_status,
            enqueue_error: enqueueResult.error,
          }, "warning");
        }
      };

      // v2.9.0: skip-attribution fast path — skip context-assembly + ai-router,
      // fire journal-extract + striking-detect directly per span.
      if (skip_attribution) {
        // HOOK: striking-detect (fire-and-forget, same as normal path)
        try {
          void fetch(STRIKING_DETECT_URL, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Edge-Secret": edgeSecret,
            },
            body: JSON.stringify({
              span_id: span.id,
              interaction_id,
              call_id: interaction_id,
              source: "segment-call",
            }),
          }).catch((e: any) => {
            console.error(`[segment-call] striking-detect (skip-attr) error: ${e?.message}`);
          });
          status.striking_detect_fired = true;
        } catch {
          // Non-fatal
        }

        // HOOK: journal-extract (fire-and-forget, no project_id)
        try {
          void fetch(JOURNAL_EXTRACT_URL, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Edge-Secret": edgeSecret,
            },
            body: JSON.stringify({
              span_id: span.id,
              interaction_id,
              skip_attribution: true,
              source: "segment-call",
            }),
          }).catch((e: any) => {
            console.error(`[segment-call] journal-extract (skip-attr) error: ${e?.message}`);
          });
          status.journal_extract_fired = true;
        } catch {
          // Non-fatal
        }

        // Mark chain as successful (no context-assembly/ai-router ran)
        status.context_assembly_status = -1; // sentinel: skipped
        status.ai_router_status = -1; // sentinel: skipped
        return status;
      }

      // context-assembly
      let contextData: any = null;
      try {
        const ctxResp = await fetch(CONTEXT_ASSEMBLY_URL, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Edge-Secret": edgeSecret,
          },
          body: JSON.stringify({
            span_id: span.id,
            interaction_id,
            source: "segment-call",
          }),
        });

        status.context_assembly_status = ctxResp.status;
        if (!ctxResp.ok) {
          status.error_code = "context_assembly_failed";
          status.error_detail = await ctxResp.text();
          await enqueueCoverageGapForFailure();
          return status;
        }

        contextData = await ctxResp.json();
      } catch (e: any) {
        status.error_code = "context_assembly_exception";
        status.error_detail = e?.message || "unknown";
        await enqueueCoverageGapForFailure();
        return status;
      }

      if (!contextData?.context_package) {
        status.error_code = "no_context_package";
        status.error_detail = "context-assembly returned no context_package";
        await enqueueCoverageGapForFailure();
        return status;
      }

      // --- EVIDENCE ASSEMBLER (gated, v2.6.0) ---
      let assemblerResult: any = null;
      let assemblerTriggered = false;
      const gatingCheck = shouldRunAssembler(contextData.context_package);

      if (ASSEMBLER_MODE !== "off" && gatingCheck.run) {
        assemblerTriggered = true;
        status.assembler_triggered = true;
        try {
          const asmResp = await fetch(EVIDENCE_ASSEMBLER_URL, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Edge-Secret": edgeSecret,
              "X-Source": "segment-call",
            },
            body: JSON.stringify({
              context_package: contextData.context_package,
              interaction_id,
              span_id: span.id,
              dry_run,
              gating_reasons: gatingCheck.reasons,
            }),
          });
          status.evidence_assembler_status = asmResp.status;
          if (asmResp.ok) {
            assemblerResult = await asmResp.json();
            // In live mode, use enriched package for ai-router
            if (ASSEMBLER_MODE === "live" && assemblerResult?.enriched_context_package) {
              contextData.context_package = assemblerResult.enriched_context_package;
            }
          }
        } catch (e: any) {
          // Fail-open: log and continue with original context_package
          console.error("[segment-call] evidence-assembler failed (fail-open):", e.message);
          status.evidence_assembler_error = e.message;
        }
      }

      // ai-router
      try {
        const routerResp = await fetch(AI_ROUTER_URL, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Edge-Secret": edgeSecret,
          },
          body: JSON.stringify({
            context_package: contextData.context_package,
            dry_run,
            source: "segment-call",
          }),
        });

        status.ai_router_status = routerResp.status;
        if (!routerResp.ok) {
          status.error_code = "ai_router_failed";
          status.error_detail = await routerResp.text();
          await enqueueCoverageGapForFailure();
          return status;
        }

        // ============================================================
        // v2.4.0: ASYNC POST-ATTRIBUTION HOOKS (fire-and-forget)
        // These are supplementary — failures do NOT block the pipeline.
        // ============================================================
        let routerData: any = null;
        try {
          routerData = await routerResp.json();
        } catch {
          // If we can't parse router response, skip hooks but don't fail
        }

        // HOOK 1: striking-detect (runs on every span)
        try {
          void fetch(STRIKING_DETECT_URL, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Edge-Secret": edgeSecret,
            },
            body: JSON.stringify({
              span_id: span.id,
              interaction_id,
              call_id: interaction_id,
              source: "segment-call",
            }),
          })
            .then(async (hookResp) => {
              if (hookResp.ok) return;
              if (!tryConsumeHookNon2xxDiagnosticBudget()) return;

              let responseDetail: string | null = null;
              try {
                responseDetail = (await hookResp.text()).slice(0, 300) || null;
              } catch {
                responseDetail = null;
              }

              console.warn(
                `[segment-call] striking-detect non-2xx response: ${hookResp.status}`,
              );
              void logDiagnostic("DOWNSTREAM_CALL_NON_2XX", {
                hook: "striking-detect",
                interaction_id,
                span_id: span.id,
                status: hookResp.status,
                response_detail: responseDetail,
                diagnostics_cap: MAX_HOOK_NON2XX_DIAGNOSTICS,
                diagnostics_used: hookNon2xxDiagnostics,
              }, "warning");
            })
            .catch((e: any) => {
              console.error(
                `[segment-call] striking-detect fire-and-forget error: ${e?.message}`,
              );
              void logDiagnostic("DOWNSTREAM_CALL_FAILED", {
                hook: "striking-detect",
                interaction_id,
                span_id: span.id,
                error: e?.message || "unknown",
              });
            });
          status.striking_detect_fired = true;
        } catch {
          await logDiagnostic("DOWNSTREAM_CALL_FAILED", {
            hook: "striking-detect",
            interaction_id,
            span_id: span.id,
            error: "dispatch_exception",
          });
          // Non-fatal
        }

        // HOOK 2: journal-extract (only when attribution assigned a project)
        const appliedProjectId = routerData?.gatekeeper?.applied_project_id;
        const routerDecision = routerData?.decision;
        if (routerDecision === "assign" && appliedProjectId) {
          try {
            fetch(JOURNAL_EXTRACT_URL, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-Edge-Secret": edgeSecret,
              },
              body: JSON.stringify({
                span_id: span.id,
                interaction_id,
                project_id: appliedProjectId,
                source: "segment-call",
              }),
            }).catch((e: any) => {
              console.error(`[segment-call] journal-extract fire-and-forget error: ${e?.message}`);
              void logDiagnostic("DOWNSTREAM_CALL_FAILED", {
                hook: "journal-extract",
                interaction_id,
                span_id: span.id,
                project_id: appliedProjectId,
                error: e?.message || "unknown",
              });
            });
            status.journal_extract_fired = true;
          } catch {
            await logDiagnostic("DOWNSTREAM_CALL_FAILED", {
              hook: "journal-extract",
              interaction_id,
              span_id: span.id,
              project_id: appliedProjectId,
              error: "dispatch_exception",
            });
            // Non-fatal
          }
        }

        // --- DECISION AUDITOR (gated, v2.6.0) ---
        let auditorResult: any = null;
        let auditorTriggered = false;

        if (
          ASSEMBLER_MODE !== "off" && routerData?.decision &&
          shouldRunAuditor(routerData.decision, routerData.confidence || 0)
        ) {
          auditorTriggered = true;
          status.auditor_triggered = true;
          try {
            const audResp = await fetch(DECISION_AUDITOR_URL, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-Edge-Secret": edgeSecret,
                "X-Source": "segment-call",
              },
              body: JSON.stringify({
                enriched_context_package: contextData.context_package,
                ai_router_decision: {
                  decision: routerData.decision,
                  confidence: routerData.confidence,
                  project_id: routerData.gatekeeper?.applied_project_id || routerData.project_id,
                  anchors: routerData.anchors || [],
                  reason_codes: routerData.reason_codes || [],
                },
                evidence_brief: assemblerResult?.evidence_brief || null,
                interaction_id,
                span_id: span.id,
                dry_run,
              }),
            });
            status.decision_auditor_status = audResp.status;
            if (audResp.ok) {
              auditorResult = await audResp.json();
              // In live mode, if auditor downgrades, log it
              if (ASSEMBLER_MODE === "live" && auditorResult?.verdict === "downgrade") {
                console.warn(`[segment-call] auditor downgraded span=${span.id}`);
              }
            }
          } catch (e: any) {
            // Fail-open: log and continue with ai-router's decision
            console.error("[segment-call] decision-auditor failed (fail-open):", e.message);
            status.decision_auditor_error = e.message;
          }
        }

        // --- PERSIST ASSEMBLER DIAGNOSTICS (v2.6.0) ---
        if (assemblerTriggered || auditorTriggered) {
          try {
            await db.from("assembler_diagnostics").insert({
              span_id: span.id,
              run_id: crypto.randomUUID(),
              assembler_triggered: assemblerTriggered,
              auditor_triggered: auditorTriggered,
              gating_reasons: gatingCheck.reasons,
              evidence_brief: assemblerResult?.evidence_brief || null,
              audit_report: auditorResult?.audit_report || auditorResult || null,
              auditor_verdict: auditorResult?.verdict || null,
              assembler_iterations: assemblerResult?.iterations_used || null,
              assembler_tool_calls: assemblerResult?.tool_calls_used || null,
              assembler_wall_clock_ms: assemblerResult?.wall_clock_ms || null,
              auditor_iterations: auditorResult?.iterations_used || null,
              auditor_tool_calls: auditorResult?.tool_calls_used || null,
              auditor_wall_clock_ms: auditorResult?.wall_clock_ms || null,
              tool_call_log: [
                ...(assemblerResult?.tool_call_log || []),
                ...(auditorResult?.tool_call_log || []),
              ],
            });
          } catch (e: any) {
            // Non-fatal: diagnostics write failure should not break the pipeline
            console.error("[segment-call] diagnostics write failed:", e.message);
          }
        }
      } catch (e: any) {
        status.error_code = "ai_router_exception";
        status.error_detail = e?.message || "unknown";
        await enqueueCoverageGapForFailure();
        return status;
      }

      return status;
    };

    // Dispatch all span chains with bounded concurrency
    const chainT0 = Date.now();
    const runLimited = createConcurrencyLimiter(SPAN_PARALLEL_CONCURRENCY);
    const settled = await Promise.allSettled(
      insertedSpans.map((span) => runLimited(() => processSpanChain(span))),
    );

    const chainStatuses: SpanChainStatus[] = settled.map((result, i) => {
      if (result.status === "fulfilled") return result.value;
      // Defense-in-depth: processSpanChain should never throw, but handle it
      const span = insertedSpans[i];
      return {
        span_id: span.id,
        span_index: span.span_index,
        context_assembly_status: null,
        ai_router_status: null,
        error_code: "span_chain_unhandled_exception",
        error_detail: String(result.reason),
        striking_detect_fired: false,
        journal_extract_fired: false,
      } as SpanChainStatus;
    });
    const chainWallClockMs = Date.now() - chainT0;

    const allSuccess = chainStatuses.every((s) =>
      (s.context_assembly_status === 200 || s.context_assembly_status === -1) &&
      (s.ai_router_status === 200 || s.ai_router_status === -1) &&
      !s.error_code
    );

    // Skip coverage invariant in skip-attribution mode (no span_attributions expected)
    const coverageInvariant = skip_attribution
      ? { before_count: 0, after_count: 0, backfilled_count: 0, backfilled_span_ids: [] as string[], error: null }
      : await enforceCoverageInvariant(db, interaction_id);
    if (coverageInvariant.backfilled_count > 0) {
      await logDiagnostic("STOPLINE_COVERAGE_BACKFILL", {
        interaction_id,
        run_id,
        stopline: "r1_stopline_zero_dropped_spans",
        before_count: coverageInvariant.before_count,
        after_count: coverageInvariant.after_count,
        backfilled_count: coverageInvariant.backfilled_count,
        sample_span_ids: coverageInvariant.backfilled_span_ids.slice(0, 10),
      }, "warning");
    }

    if (coverageInvariant.error || coverageInvariant.after_count > 0) {
      await logDiagnostic("STOPLINE_COVERAGE_GAP", {
        reason: coverageInvariant.error || "uncovered_spans_remain_after_backfill",
        interaction_id,
        run_id,
        stopline: "r1_stopline_zero_dropped_spans",
        before_count: coverageInvariant.before_count,
        after_count: coverageInvariant.after_count,
        backfilled_count: coverageInvariant.backfilled_count,
        sample_span_ids: coverageInvariant.backfilled_span_ids.slice(0, 10),
      });
      return new Response(
        JSON.stringify({
          ok: false,
          error: "coverage_invariant_failed",
          error_code: "coverage_invariant_failed",
          run_id,
          version: SEGMENT_CALL_VERSION,
          interaction_id,
          transcript_source: transcriptSource,
          spans_written,
          spans_write_ok,
          span_ids: spanIds,
          span_count: spanCount,
          segmenter_version: segmenterVersion,
          segmentation_channel: segmentationChannel,
          segmenter_warnings: segmenterWarnings,
          parent_interaction_sync: {
            applied: parent_interaction_sync_applied,
            transcript_chars: parent_interaction_transcript_chars,
            error: parent_interaction_sync_error,
          },
          chain: {
            attempted: true,
            auth_mode: "X-Edge-Secret",
            parallel_concurrency: SPAN_PARALLEL_CONCURRENCY,
            wall_clock_ms: chainWallClockMs,
            statuses: chainStatuses,
          },
          coverage_invariant: coverageInvariant,
          dry_run,
          ms: Date.now() - t0,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    if (!allSuccess) {
      await logDiagnostic("DOWNSTREAM_CALL_FAILED", {
        reason: "chain_failed",
        interaction_id,
        run_id,
        failed_count: chainStatuses.filter((s) => Boolean(s.error_code)).length,
        sample_failures: chainStatuses
          .filter((s) => Boolean(s.error_code))
          .slice(0, 5)
          .map((s) => ({
            span_id: s.span_id,
            span_index: s.span_index,
            context_assembly_status: s.context_assembly_status,
            ai_router_status: s.ai_router_status,
            error_code: s.error_code,
          })),
      });
      return new Response(
        JSON.stringify({
          ok: false,
          error: "chain_failed",
          error_code: "chain_failed",
          run_id,
          version: SEGMENT_CALL_VERSION,
          interaction_id,
          transcript_source: transcriptSource,
          spans_written,
          spans_write_ok,
          span_ids: spanIds,
          span_count: spanCount,
          segmenter_version: segmenterVersion,
          segmentation_channel: segmentationChannel,
          segmenter_warnings: segmenterWarnings,
          parent_interaction_sync: {
            applied: parent_interaction_sync_applied,
            transcript_chars: parent_interaction_transcript_chars,
            error: parent_interaction_sync_error,
          },
          chain: {
            attempted: true,
            auth_mode: "X-Edge-Secret",
            parallel_concurrency: SPAN_PARALLEL_CONCURRENCY,
            wall_clock_ms: chainWallClockMs,
            statuses: chainStatuses,
          },
          coverage_invariant: coverageInvariant,
          dry_run,
          ms: Date.now() - t0,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    // ============================================================
    // v2.5.0: CALL-LEVEL SUMMARY HOOK (fire-and-forget)
    // Trigger once after all spans finish context-assembly + ai-router.
    // ============================================================
    let generateSummaryFired = false;
    if (!dry_run) {
      try {
        fetch(GENERATE_SUMMARY_URL, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Edge-Secret": edgeSecret,
          },
          body: JSON.stringify({
            interaction_id,
            source: "segment-call",
          }),
        }).catch((e: any) => {
          console.error(`[segment-call] generate-summary fire-and-forget error: ${e?.message}`);
          void logDiagnostic("DOWNSTREAM_CALL_FAILED", {
            hook: "generate-summary",
            interaction_id,
            error: e?.message || "unknown",
          });
        });
        generateSummaryFired = true;
      } catch {
        await logDiagnostic("DOWNSTREAM_CALL_FAILED", {
          hook: "generate-summary",
          interaction_id,
          error: "dispatch_exception",
        });
        // Non-fatal
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        run_id,
        version: SEGMENT_CALL_VERSION,
        interaction_id,
        transcript_source: transcriptSource,
        spans_written,
        spans_write_ok,
        span_ids: spanIds,
        span_count: spanCount,
        segmenter_version: segmenterVersion,
        segmentation_channel: segmentationChannel,
        segmenter_warnings: segmenterWarnings,
        parent_interaction_sync: {
          applied: parent_interaction_sync_applied,
          transcript_chars: parent_interaction_transcript_chars,
          error: parent_interaction_sync_error,
        },
        chain: {
          attempted: true,
          auth_mode: "X-Edge-Secret",
          parallel_concurrency: SPAN_PARALLEL_CONCURRENCY,
          wall_clock_ms: chainWallClockMs,
          statuses: chainStatuses,
        },
        coverage_invariant: coverageInvariant,
        post_hooks: {
          generate_summary_fired: generateSummaryFired,
        },
        dry_run,
        skip_attribution,
        ms: Date.now() - t0,
      }),
      { status: 200, headers: jsonHeaders },
    );
  } catch (e: any) {
    // Defense-in-depth: catch any unhandled exception in the handler
    console.error("segment-call unhandled:", e.message);
    return new Response(
      JSON.stringify({
        ok: false,
        run_id,
        error_code: "unhandled_error",
        error: e.message,
        segment_call_version: SEGMENT_CALL_VERSION,
      }),
      { status: 500, headers: jsonHeaders },
    );
  }
});
