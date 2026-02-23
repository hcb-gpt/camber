/**
 * admin-reseed Edge Function
 * Re-chunk an interaction's conversation spans (non-destructive)
 *
 * @version 1.5.0
 * @date 2026-01-31
 * @purpose Supersede old spans and create new spans for an interaction
 *
 * TERMINOLOGY (STRAT directive 2026-01-31):
 * - Canonical term is "chunking" (not "segmentation")
 * - This endpoint performs "re-chunking" of conversation spans
 * - DB column names unchanged (segmenter_version, segment_reason, etc.)
 *
 * AUTH:
 * - Internal control-plane endpoint (not user-facing)
 * - Uses Pattern A: X-Edge-Secret + source allowlist
 * - verify_jwt=false
 *
 * BEHAVIOR:
 * 1. If any active span has human lock: return 409 human_lock_present
 * 2. Idempotency: if idempotency_key exists, return stored receipt (no mutation)
 * 3. Non-destructive: supersede old spans (is_superseded=true), insert new spans
 * 4. After rechunk, optionally reroute based on mode
 *
 * MODES (legacy names, concept is "rechunk"):
 * - resegment_only (default): Just rechunk, don't call downstream
 * - resegment_and_reroute: Rechunk + call context-assembly + ai-router
 * - reseed_and_close_loop: Rechunk + reroute + integrity close-loop guarantees
 *
 * FAIL CLOSED: Any DB write failure returns 500
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const VERSION = "1.8.0"; // v1.8.0: add force param for FK cascade delete before re-segmentation
const ALLOWED_SOURCES = ["admin-reseed", "system"];
const CLOSE_LOOP_MAX_ATTEMPTS = 2;
const CLOSE_LOOP_MODEL_ID = "admin-reseed-close-loop";
const CLOSE_LOOP_PROMPT_VERSION = "v1";
const CARRYFORWARD_MODEL_ID = "admin-reseed-human-lock-carryforward";
const CARRYFORWARD_PROMPT_VERSION = "v1";
const REROUTE_CONCURRENCY = Math.max(1, Number(Deno.env.get("ADMIN_RESEED_REROUTE_CONCURRENCY") || "4"));
const INTERNAL_CALL_TIMEOUT_MS = Math.max(5000, Number(Deno.env.get("ADMIN_RESEED_INTERNAL_TIMEOUT_MS") || "18000"));

// ============================================================
// STRUCTURED LOGGING (per GPT-DEV-6 spec)
// ============================================================
type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR";

interface StructuredLog {
  ts: string;
  level: LogLevel;
  service: string;
  function: string;
  event: string;
  interaction_id: string | null;
  generation: number | null;
  request_id: string;
  correlation_id: string;
  segmenter_version: string | null;
  [key: string]: unknown;
}

function structuredLog(
  level: LogLevel,
  event: string,
  requestId: string,
  interactionId: string | null,
  generation: number | null,
  extra: Record<string, unknown> = {},
): void {
  const log: StructuredLog = {
    ts: new Date().toISOString(),
    level,
    service: "edge-function",
    function: "admin-reseed",
    event,
    interaction_id: interactionId,
    generation,
    request_id: requestId,
    correlation_id: `${interactionId || "unknown"}:${generation ?? 0}:${requestId}`,
    segmenter_version: (extra.segmenter_version as string) || null,
    ...extra,
  };
  if (level === "ERROR") {
    console.error(JSON.stringify(log));
  } else {
    console.log(JSON.stringify(log));
  }
}

// Single-span guard thresholds
const LONG_TRANSCRIPT_THRESHOLD = 2000; // chars
const RETRY_MIN_SEGMENT_CHARS = 100; // smaller for retry to encourage more splits

type SegmentFromLLM = {
  span_index: number;
  char_start: number;
  char_end: number;
  boundary_reason: string;
  confidence: number;
  boundary_quote: string | null;
};

interface ReseedRequest {
  interaction_id: string;
  reason: string;
  idempotency_key: string;
  mode?: "resegment_only" | "resegment_and_reroute" | "reseed_and_close_loop";
  requested_by?: string;
  force?: boolean;
}

interface ReseedReceipt {
  ok: boolean;
  interaction_id: string;
  idempotency_key: string;
  mode: string;
  span_count_before: number;
  span_count_after: number;
  attrib_count_before: number;
  attrib_count_after: number;
  status: "success" | "blocked_human_lock" | "error";
  human_locked_spans?: string[];
  human_lock_count?: number;
  human_lock_carryforward_count?: number;
  new_span_ids?: string[];
  superseded_span_ids?: string[];
  reroute_triggered?: boolean;
  reroute_attempted?: number;
  reroute_succeeded?: number;
  reroute_failed?: number;
  insert_conflict_recovered?: boolean;
  conflict_constraint?: string | null;
  adopted_generation?: number | null;
  close_loop_applied?: boolean;
  close_loop_attempts?: number;
  close_loop_missing_before?: number;
  close_loop_missing_after?: number;
  close_loop_fallback_inserted?: number;
  close_loop_stale_pending_dismissed?: number;
  close_loop_pending_on_superseded_after?: number;
  close_loop_pending_null_after?: number;
  ms?: number;
}

type HumanLockedSpanInfo = {
  span_id: string;
  span_index: number;
  applied_project_id: string;
};

Deno.serve(async (req: Request) => {
  const t0 = Date.now();
  console.log(`[admin-reseed ${VERSION}] Processing request`);

  // ========================================
  // 1. AUTH: X-Edge-Secret + source allowlist
  // ========================================
  const authResult = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!authResult.ok) {
    return authErrorResponse(authResult.error_code!);
  }

  // ========================================
  // 2. VALIDATE REQUEST
  // ========================================
  if (req.method !== "POST") {
    return jsonResponse({ error: "POST only" }, 405);
  }

  let body: ReseedRequest;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const {
    interaction_id,
    reason,
    idempotency_key,
    mode = "resegment_only",
    requested_by = "system",
    force = false,
  } = body;

  // Validate required fields
  if (!interaction_id) {
    return jsonResponse({ error: "missing_interaction_id" }, 400);
  }
  if (!reason || reason.trim().length === 0) {
    return jsonResponse({ error: "missing_reason" }, 400);
  }
  if (!idempotency_key || idempotency_key.trim().length === 0) {
    return jsonResponse({ error: "missing_idempotency_key" }, 400);
  }
  if (!["resegment_only", "resegment_and_reroute", "reseed_and_close_loop"].includes(mode)) {
    return jsonResponse({
      error: "invalid_mode",
      valid: ["resegment_only", "resegment_and_reroute", "reseed_and_close_loop"],
    }, 400);
  }

  const rerouteMode = mode === "resegment_and_reroute" || mode === "reseed_and_close_loop";

  // ========================================
  // 3. INIT DB CLIENT
  // ========================================
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ========================================
  // 4. IDEMPOTENCY CHECK
  // If idempotency_key exists, return stored receipt
  // ========================================
  const { data: existingLog } = await db
    .from("override_log")
    .select("effects_receipt, reseed_status")
    .eq("idempotency_key", idempotency_key)
    .maybeSingle();

  if (existingLog) {
    console.log(`[admin-reseed] Idempotent replay for key=${idempotency_key}`);
    const receipt = existingLog.effects_receipt as ReseedReceipt | null;
    return jsonResponse({
      ok: existingLog.reseed_status === "success",
      idempotent_replay: true,
      receipt: receipt || { status: existingLog.reseed_status },
      ms: Date.now() - t0,
    }, 200);
  }

  // ========================================
  // 5. VERIFY INTERACTION EXISTS
  // ========================================
  const { data: interaction, error: intErr } = await db
    .from("interactions")
    .select("interaction_id")
    .eq("interaction_id", interaction_id)
    .maybeSingle();

  if (intErr || !interaction) {
    return jsonResponse({
      ok: false,
      error: "interaction_not_found",
      interaction_id,
    }, 404);
  }

  // ========================================
  // 6. FETCH ACTIVE SPANS + CHECK HUMAN LOCKS
  // POLICY: Active spans only (is_superseded=false)
  // ========================================
  const { data: activeSpans, error: spanErr } = await db
    .from("conversation_spans")
    .select("id, span_index, segment_generation")
    .eq("interaction_id", interaction_id)
    .eq("is_superseded", false)
    .order("span_index");

  if (spanErr) {
    console.error("[admin-reseed] Failed to fetch spans:", spanErr.message);
    return jsonResponse({ ok: false, error: "db_read_failed", detail: spanErr.message }, 500);
  }

  const activeSpanIds = (activeSpans || []).map((s) => s.id);
  const spanCountBefore = activeSpanIds.length;
  const currentGeneration = Math.max(0, ...((activeSpans || []).map((s) => s.segment_generation || 1)));

  // Check for human locks on these spans
  let humanLockedSpans: string[] = [];
  let humanLockedSpanInfos: HumanLockedSpanInfo[] = [];
  let attribCountBefore = 0;

  if (activeSpanIds.length > 0) {
    const spanIdToIndex = new Map<string, number>(
      (activeSpans || []).map((s) => [String(s.id), Number(s.span_index ?? 0)]),
    );

    const { data: attribs, error: attribErr } = await db
      .from("span_attributions")
      .select("span_id, attribution_lock, applied_project_id")
      .in("span_id", activeSpanIds);

    if (attribErr) {
      console.error("[admin-reseed] Failed to fetch attributions:", attribErr.message);
      return jsonResponse({ ok: false, error: "db_read_failed", detail: attribErr.message }, 500);
    }

    attribCountBefore = (attribs || []).length;
    const locked = (attribs || [])
      .filter((a) => a.attribution_lock === "human" && a.applied_project_id)
      .map((a) => ({
        span_id: String(a.span_id),
        span_index: spanIdToIndex.get(String(a.span_id)) ?? 0,
        applied_project_id: String(a.applied_project_id),
      }));

    // De-dupe per span_id (span_attributions can have multiple rows per span_id).
    const seen = new Set<string>();
    humanLockedSpanInfos = [];
    for (const row of locked) {
      if (seen.has(row.span_id)) continue;
      seen.add(row.span_id);
      humanLockedSpanInfos.push(row);
    }

    humanLockedSpans = humanLockedSpanInfos.map((r) => r.span_id);
  }

  // ========================================
  // 7. FORCE CASCADE DELETE (when force=true)
  // Deletes all dependent data in FK order before re-segmenting.
  // Order: striking_signals → journal_claims → span_attributions → conversation_spans
  // ========================================
  if (force) {
    const { data: allSpans, error: allSpanErr } = await db
      .from("conversation_spans")
      .select("id")
      .eq("interaction_id", interaction_id);

    if (allSpanErr) {
      console.error("[admin-reseed] Force cascade: failed to fetch all spans:", allSpanErr.message);
      return jsonResponse({ ok: false, error: "db_read_failed", detail: allSpanErr.message }, 500);
    }

    const allSpanIdsForDelete = (allSpans || []).map((s: any) => s.id as string);

    if (allSpanIdsForDelete.length > 0) {
      // 1. striking_signals
      const { error: ssErr } = await db
        .from("striking_signals")
        .delete()
        .in("span_id", allSpanIdsForDelete);
      if (ssErr) {
        console.error("[admin-reseed] Force cascade: striking_signals delete failed:", ssErr.message);
        return jsonResponse(
          { ok: false, error: "cascade_delete_failed", detail: `striking_signals: ${ssErr.message}` },
          500,
        );
      }

      // 2. journal_claims
      const { error: jcErr } = await db
        .from("journal_claims")
        .delete()
        .in("span_id", allSpanIdsForDelete);
      if (jcErr) {
        console.error("[admin-reseed] Force cascade: journal_claims delete failed:", jcErr.message);
        return jsonResponse(
          { ok: false, error: "cascade_delete_failed", detail: `journal_claims: ${jcErr.message}` },
          500,
        );
      }

      // 3. span_attributions
      const { error: saErr } = await db
        .from("span_attributions")
        .delete()
        .in("span_id", allSpanIdsForDelete);
      if (saErr) {
        console.error("[admin-reseed] Force cascade: span_attributions delete failed:", saErr.message);
        return jsonResponse({
          ok: false,
          error: "cascade_delete_failed",
          detail: `span_attributions: ${saErr.message}`,
        }, 500);
      }

      // 4. conversation_spans (all for this interaction)
      const { error: csErr } = await db
        .from("conversation_spans")
        .delete()
        .eq("interaction_id", interaction_id);
      if (csErr) {
        console.error("[admin-reseed] Force cascade: conversation_spans delete failed:", csErr.message);
        return jsonResponse({
          ok: false,
          error: "cascade_delete_failed",
          detail: `conversation_spans: ${csErr.message}`,
        }, 500);
      }

      console.log(
        `[admin-reseed] Force cascade delete completed: ${allSpanIdsForDelete.length} spans + dependencies removed`,
      );
    }
  }

  // ========================================
  // 7b. HUMAN LOCK GATE (skipped when force=true)
  // POLICY: Do NOT block reseed on human locks.
  // Instead, carry forward human locks to replacement spans by span_index.
  // ========================================
  if (!force && humanLockedSpanInfos.length > 0) {
    console.log(`[admin-reseed] Found ${humanLockedSpanInfos.length} human-locked spans; will carry forward`);
  }

  // ========================================
  // 8. SUPERSEDE OLD SPANS (non-destructive; skipped when force=true)
  // ========================================
  const reseedActionId = crypto.randomUUID();
  const newGeneration = force ? 1 : currentGeneration + 1;

  if (!force && activeSpanIds.length > 0) {
    const { error: supersedErr } = await db
      .from("conversation_spans")
      .update({
        is_superseded: true,
        superseded_at: new Date().toISOString(),
        superseded_by_action_id: reseedActionId,
      })
      .in("id", activeSpanIds);

    if (supersedErr) {
      console.error("[admin-reseed] Failed to supersede spans:", supersedErr.message);
      return jsonResponse({ ok: false, error: "db_write_failed", detail: supersedErr.message }, 500);
    }
  }

  // ========================================
  // 9. FETCH TRANSCRIPT FOR RECHUNKING
  // ========================================
  // Try transcripts_comparison first (canonical source)
  const { data: transcriptData } = await db
    .from("transcripts_comparison")
    .select("transcript, words")
    .eq("interaction_id", interaction_id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  let transcript = (transcriptData?.transcript || "").trim();
  let transcriptSource: string | null = transcript ? "transcripts_comparison" : null;

  // Fallback 2: canonical raw call transcript source
  if (!transcript) {
    const { data: callsRawData, error: callsRawErr } = await db
      .from("calls_raw")
      .select("transcript")
      .eq("interaction_id", interaction_id)
      .order("ingested_at_utc", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (callsRawErr) {
      console.warn("[admin-reseed] Failed to fetch calls_raw transcript:", callsRawErr.message);
    } else if (callsRawData?.transcript) {
      transcript = callsRawData.transcript.trim();
      transcriptSource = "calls_raw";
      console.log(
        `[admin-reseed] Using calls_raw transcript fallback for interaction=${interaction_id}, length=${transcript.length}`,
      );
    }
  }

  // Fallback: reconstruct from existing spans if no transcript_comparison
  if (!transcript) {
    // Try active spans first, then fall back to most recent superseded generation
    let fallbackSpanIds = activeSpanIds;
    let fallbackSource = "active";

    if (fallbackSpanIds.length === 0) {
      // No active spans - get most recent superseded generation
      const { data: supersededSpans } = await db
        .from("conversation_spans")
        .select("id, segment_generation")
        .eq("interaction_id", interaction_id)
        .eq("is_superseded", true)
        .order("segment_generation", { ascending: false })
        .order("span_index");

      if (supersededSpans && supersededSpans.length > 0) {
        const maxGen = supersededSpans[0].segment_generation;
        fallbackSpanIds = supersededSpans
          .filter((s) => s.segment_generation === maxGen)
          .map((s) => s.id);
        fallbackSource = `superseded_gen${maxGen}`;
      }
    }

    if (fallbackSpanIds.length > 0) {
      const { data: spanTexts } = await db
        .from("conversation_spans")
        .select("transcript_segment, span_index")
        .in("id", fallbackSpanIds)
        .order("span_index");

      if (spanTexts && spanTexts.length > 0) {
        transcript = spanTexts
          .map((s) => s.transcript_segment || "")
          .filter(Boolean)
          .join("\n\n");
        transcriptSource = `reconstructed_${fallbackSource}_spans`;
        console.log(
          `[admin-reseed] Reconstructed transcript from ${spanTexts.length} ${fallbackSource} spans, ${transcript.length} chars`,
        );
      }
    }
  }

  // ========================================
  // 10. CREATE NEW SPANS (segment-llm)
  // POLICY (STRAT TURN:82): admin-reseed must use segment-llm (same as segment-call),
  // not a trivial single-span chunker.
  // ========================================
  const newSpanIds: string[] = [];
  let insertConflictRecoveredOverall = false;
  let conflictConstraintOverall: string | null = null;
  let adoptedGenerationOverall: number | null = null;

  // Generate request_id for structured logging
  const requestId = crypto.randomUUID();

  if (transcript.length > 0) {
    const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET");
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const segmentLLMUrl = `${supabaseUrl}/functions/v1/segment-llm`;

    let segments: SegmentFromLLM[] = [];
    let segmenterVersion = "fallback_trivial_v1";
    const segmenterWarnings: string[] = [];
    const max_segments = 10;
    const min_segment_chars = 200;
    const transcriptChars = transcript.length;

    // Structured log: reseed_start
    structuredLog("INFO", "reseed_start", requestId, interaction_id, newGeneration, {
      transcript_chars: transcriptChars,
      reseed_mode: mode,
      reroute: rerouteMode,
      transcript_source: transcriptSource || "none",
    });

    // Structured log: reseed_segment_request
    structuredLog("INFO", "reseed_segment_request", requestId, interaction_id, newGeneration, {
      transcript_chars: transcriptChars,
      segmenter_params: { max_segments, min_segment_chars },
    });

    const segmentT0 = Date.now();

    try {
      const llmResp = await fetch(segmentLLMUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret || "",
          "x-request-id": requestId,
        },
        body: JSON.stringify({
          interaction_id,
          transcript,
          source: "admin-reseed",
          max_segments,
          min_segment_chars,
        }),
      });

      if (!llmResp.ok) {
        const _errBody = await llmResp.text().catch(() => "");
        structuredLog("ERROR", "reseed_segment_error", requestId, interaction_id, newGeneration, {
          error_code: `http_${llmResp.status}`,
          error_class: "segment_llm_http_error",
          segmenter_latency_ms: Date.now() - segmentT0,
        });
        segmenterWarnings.push(`segment_llm_http_${llmResp.status}`);
      } else {
        const llmData = await llmResp.json().catch(() => null);
        if (llmData?.ok && Array.isArray(llmData.segments) && llmData.segments.length > 0) {
          segments = llmData.segments;
          segmenterVersion = llmData.segmenter_version || "segment-llm_v1.0.0";
          if (Array.isArray(llmData.warnings)) segmenterWarnings.push(...llmData.warnings);

          // Structured log: reseed_segment_result
          structuredLog("INFO", "reseed_segment_result", requestId, interaction_id, newGeneration, {
            segments_returned: segments.length,
            segmenter_latency_ms: Date.now() - segmentT0,
            segmenter_version: segmenterVersion,
          });
        } else {
          segmenterWarnings.push("segment_llm_invalid_response");
        }
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "unknown";
      structuredLog("ERROR", "reseed_segment_error", requestId, interaction_id, newGeneration, {
        error_code: "fetch_error",
        error_class: msg,
        segmenter_latency_ms: Date.now() - segmentT0,
      });
      segmenterWarnings.push(`segment_llm_error:${msg}`);
    }

    // ========================================
    // SINGLE-SPAN GUARD (Phase 1 P0 requirement)
    // If transcript > 2000 chars AND segment-llm returns 1 span:
    // 1. Retry with stricter params
    // 2. If still 1 span, use deterministic fallback
    // ========================================
    const isLongTranscript = transcriptChars > LONG_TRANSCRIPT_THRESHOLD;
    const isSingleSpan = segments.length === 1;

    if (isLongTranscript && isSingleSpan) {
      structuredLog("WARN", "reseed_retry_segment_request", requestId, interaction_id, newGeneration, {
        retry_reason: "long_transcript_single_segment",
        transcript_chars: transcriptChars,
        segmenter_params: { max_segments, min_segment_chars: RETRY_MIN_SEGMENT_CHARS },
      });

      const retryT0 = Date.now();

      try {
        const retryResp = await fetch(segmentLLMUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Edge-Secret": edgeSecret || "",
            "x-request-id": requestId,
          },
          body: JSON.stringify({
            interaction_id,
            transcript,
            source: "admin-reseed",
            max_segments,
            min_segment_chars: RETRY_MIN_SEGMENT_CHARS,
            // Hint to LLM to be more aggressive about splitting
            strict_split: true,
          }),
        });

        if (retryResp.ok) {
          const retryData = await retryResp.json().catch(() => null);
          if (retryData?.ok && Array.isArray(retryData.segments) && retryData.segments.length > 1) {
            segments = retryData.segments;
            segmenterVersion = retryData.segmenter_version || "segment-llm_v1.0.0";
            segmenterWarnings.push("retry_produced_multiple_spans");

            structuredLog("INFO", "reseed_retry_segment_result", requestId, interaction_id, newGeneration, {
              segments_returned: segments.length,
              segmenter_latency_ms: Date.now() - retryT0,
              segmenter_version: segmenterVersion,
            });
          } else {
            // Retry still returned 1 span - use deterministic fallback
            structuredLog("WARN", "reseed_single_segment_fallback_warning", requestId, interaction_id, newGeneration, {
              transcript_chars: transcriptChars,
              segments_returned: 1,
              fallback_reason: "retry_still_single_span",
            });

            // Deterministic fallback: split by paragraphs or fixed chunks
            segments = deterministicSplit(transcript, transcriptChars);
            segmenterVersion = "fallback_deterministic_v1";
            segmenterWarnings.push("deterministic_fallback_after_retry");
          }
        } else {
          // Retry failed - use deterministic fallback
          structuredLog("WARN", "reseed_single_segment_fallback_warning", requestId, interaction_id, newGeneration, {
            transcript_chars: transcriptChars,
            segments_returned: 1,
            fallback_reason: "retry_http_failed",
          });

          segments = deterministicSplit(transcript, transcriptChars);
          segmenterVersion = "fallback_deterministic_v1";
          segmenterWarnings.push("deterministic_fallback_retry_failed");
        }
      } catch (retryErr: unknown) {
        const msg = retryErr instanceof Error ? retryErr.message : "unknown";
        structuredLog("WARN", "reseed_single_segment_fallback_warning", requestId, interaction_id, newGeneration, {
          transcript_chars: transcriptChars,
          segments_returned: 1,
          fallback_reason: `retry_error:${msg}`,
        });

        segments = deterministicSplit(transcript, transcriptChars);
        segmenterVersion = "fallback_deterministic_v1";
        segmenterWarnings.push(`deterministic_fallback_retry_error:${msg}`);
      }
    }

    // Safety net: ensure we always write at least one span covering the transcript.
    if (!segments || segments.length === 0) {
      segments = [{
        span_index: 0,
        char_start: 0,
        char_end: transcript.length,
        boundary_reason: "fallback_full_call",
        confidence: 1.0,
        boundary_quote: null,
      }];
    }

    // Boundary guardrails: clamp, sort, repair contiguity
    segments = segments
      .map((s, i) => ({
        ...s,
        span_index: i,
        char_start: Math.max(0, Math.min(transcript.length, Math.floor(Number(s.char_start)))),
        char_end: Math.max(0, Math.min(transcript.length, Math.floor(Number(s.char_end)))),
      }))
      .sort((a, b) => a.char_start - b.char_start);

    // Repair to full coverage / contiguity
    let cursor = 0;
    const repaired: SegmentFromLLM[] = [];
    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i];
      const start = Math.max(cursor, seg.char_start);
      let end = Math.max(start, seg.char_end);
      if (i === segments.length - 1) end = transcript.length;
      if (start === end) continue;
      repaired.push({ ...seg, span_index: repaired.length, char_start: start, char_end: end });
      cursor = end;
    }
    if (repaired.length === 0) {
      repaired.push({
        span_index: 0,
        char_start: 0,
        char_end: transcript.length,
        boundary_reason: "fallback_full_call",
        confidence: 1.0,
        boundary_quote: null,
      });
    }

    // Merge undersized segments into previous where possible
    const merged: SegmentFromLLM[] = [];
    for (const seg of repaired) {
      const len = seg.char_end - seg.char_start;
      if (len < min_segment_chars && merged.length > 0) {
        const prev = merged[merged.length - 1];
        prev.char_end = seg.char_end;
        prev.boundary_reason = prev.boundary_reason || seg.boundary_reason;
        continue;
      }
      merged.push(seg);
    }
    merged[merged.length - 1].char_end = transcript.length;
    merged.forEach((s, i) => (s.span_index = i));

    const spanRowsWithMetadata = merged.map((seg) => {
      const segmentText = transcript.slice(seg.char_start, seg.char_end);
      const wordCount = segmentText.split(/\s+/).filter(Boolean).length;
      return {
        id: crypto.randomUUID(),
        interaction_id,
        span_index: seg.span_index,
        char_start: seg.char_start,
        char_end: seg.char_end,
        transcript_segment: segmentText,
        word_count: wordCount,
        segmenter_version: segmenterVersion,
        segment_reason: `reseed:${reason}|${seg.boundary_reason}`,
        segment_generation: newGeneration,
        is_superseded: false,
        segment_metadata: {
          confidence: seg.confidence,
          boundary_quote: seg.boundary_quote,
          warnings: segmenterWarnings,
          source: "admin-reseed",
        },
      };
    });

    // Insert attempt #1 (with segment_metadata); fallback if column not present.
    let inserted: { id: string; span_index: number }[] = [];
    let insertConflictRecovered = false;
    let conflictConstraint: string | null = null;
    let adoptedGeneration: number | null = null;

    const adoptActiveSpansAfterConflict = async (): Promise<boolean> => {
      const active = await fetchLatestActiveSpans(db, interaction_id);
      if (active.length === 0) return false;
      inserted = active.map((row) => ({ id: row.id, span_index: row.span_index }));
      adoptedGeneration = active[0]?.segment_generation ?? null;
      insertConflictRecovered = true;
      segmenterWarnings.push("insert_conflict_recovered_adopt_active");
      structuredLog("WARN", "reseed_insert_conflict_recovered", requestId, interaction_id, newGeneration, {
        conflict_constraint: conflictConstraint,
        adopted_spans: inserted.length,
        adopted_generation: adoptedGeneration,
      });
      return true;
    };

    const ins1 = await db
      .from("conversation_spans")
      .insert(spanRowsWithMetadata)
      .select("id, span_index");

    if (ins1.error) {
      const msg = (ins1.error.message || "").toLowerCase();
      const missingMetaCol = msg.includes("segment_metadata") && msg.includes("does not exist");
      const duplicateActiveUnique = isActiveSpanUniqueConflict(ins1.error);
      if (duplicateActiveUnique) {
        conflictConstraint = "conversation_spans_active_unique";
        const adopted = await adoptActiveSpansAfterConflict();
        if (!adopted) {
          return jsonResponse({
            ok: false,
            error: "db_write_failed",
            detail: "duplicate_conflict_recovery_failed_no_active_spans",
          }, 500);
        }
      } else if (!missingMetaCol) {
        console.error("[admin-reseed] Failed to insert new spans:", ins1.error.message);
        // FAIL CLOSED: rollback by marking old spans as not superseded
        if (activeSpanIds.length > 0) {
          await db
            .from("conversation_spans")
            .update({
              is_superseded: false,
              superseded_at: null,
              superseded_by_action_id: null,
            })
            .in("id", activeSpanIds);
        }
        return jsonResponse({ ok: false, error: "db_write_failed", detail: ins1.error.message }, 500);
      }

      if (missingMetaCol && !insertConflictRecovered) {
        const spanRowsNoMetadata = spanRowsWithMetadata.map(({ segment_metadata: _segment_metadata, ...rest }) => rest);
        const ins2 = await db
          .from("conversation_spans")
          .insert(spanRowsNoMetadata as any)
          .select("id, span_index");

        if (ins2.error) {
          if (isActiveSpanUniqueConflict(ins2.error)) {
            conflictConstraint = "conversation_spans_active_unique";
            const adopted = await adoptActiveSpansAfterConflict();
            if (!adopted) {
              return jsonResponse({
                ok: false,
                error: "db_write_failed",
                detail: "duplicate_conflict_recovery_failed_no_active_spans",
              }, 500);
            }
          } else {
            console.error("[admin-reseed] Failed to insert new spans:", ins2.error.message);
            if (activeSpanIds.length > 0) {
              await db
                .from("conversation_spans")
                .update({
                  is_superseded: false,
                  superseded_at: null,
                  superseded_by_action_id: null,
                })
                .in("id", activeSpanIds);
            }
            return jsonResponse({ ok: false, error: "db_write_failed", detail: ins2.error.message }, 500);
          }
        } else {
          inserted = (ins2.data || []) as any;
        }
      }
    } else {
      inserted = (ins1.data || []) as any;
    }

    inserted.sort((a, b) => a.span_index - b.span_index);
    newSpanIds.push(...inserted.map((r) => r.id));

    // Structured log: reseed_spans_inserted
    structuredLog("INFO", "reseed_spans_inserted", requestId, interaction_id, newGeneration, {
      spans_inserted: newSpanIds.length,
      superseded_count: activeSpanIds.length,
      spans_active_after: newSpanIds.length,
      segmenter_version: segmenterVersion,
      insert_conflict_recovered: insertConflictRecovered,
      conflict_constraint: conflictConstraint,
      adopted_generation: adoptedGeneration,
    });

    if (insertConflictRecovered) {
      segmenterWarnings.push("active_unique_conflict_recovered");
    }
    insertConflictRecoveredOverall = insertConflictRecovered;
    conflictConstraintOverall = conflictConstraint;
    adoptedGenerationOverall = adoptedGeneration;
  }

  // ========================================
  // 10b. CARRY FORWARD HUMAN LOCKS (SPAN-INDEX MAP)
  // - Preserve Chad GT corrections across reseeds.
  // - Insert a human-locked span_attributions row for replacement spans.
  // ========================================
  let humanLockCarryforwardCount = 0;
  if (!force && humanLockedSpanInfos.length > 0 && newSpanIds.length > 0) {
    const spanIndexToNewSpanId = new Map<number, string>();
    for (const row of newSpanIds.map((id, idx) => ({ id, idx }))) {
      // newSpanIds are already ordered by span_index insertion order (we sorted `inserted`).
      // Use positional index as a fallback. If `inserted` contained explicit span_index,
      // its order matches, and span_index==position in most reseeds.
      spanIndexToNewSpanId.set(row.idx, row.id);
    }

    // Prefer explicit mapping from inserted rows if available (span_index -> id)
    try {
      const { data: newSpans } = await db
        .from("conversation_spans")
        .select("id, span_index")
        .in("id", newSpanIds);
      for (const s of (newSpans || []) as any[]) {
        if (s?.span_index !== undefined && s?.id) {
          spanIndexToNewSpanId.set(Number(s.span_index), String(s.id));
        }
      }
    } catch (_e) {
      // Best-effort only; fallback mapping remains.
    }

    const nowIso = new Date().toISOString();
    const carryRows = humanLockedSpanInfos
      .map((info) => {
        const newSpanId = spanIndexToNewSpanId.get(info.span_index);
        if (!newSpanId) return null;
        return {
          span_id: newSpanId,
          project_id: info.applied_project_id,
          decision: "assign",
          confidence: 1,
          attribution_source: "admin_reseed_human_lock_carryforward",
          reasoning: "admin-reseed: carried forward attribution_lock=human from superseded span by span_index",
          attribution_lock: "human",
          applied_project_id: info.applied_project_id,
          applied_at_utc: nowIso,
          needs_review: false,
          model_id: CARRYFORWARD_MODEL_ID,
          prompt_version: CARRYFORWARD_PROMPT_VERSION,
          attributed_by: `admin-reseed-${VERSION}`,
          attributed_at: nowIso,
          raw_response: {
            source: "admin-reseed",
            carryforward: true,
            from_span_id: info.span_id,
            from_span_index: info.span_index,
            interaction_id,
          },
        };
      })
      .filter(Boolean) as any[];

    if (carryRows.length > 0) {
      const { data: insertedRows, error: carryErr } = await db
        .from("span_attributions")
        .upsert(carryRows, { onConflict: "span_id,model_id,prompt_version", ignoreDuplicates: false })
        .select("span_id");

      if (carryErr) {
        console.error("[admin-reseed] Human-lock carryforward failed:", carryErr.message);
        // Fail closed on carryforward: better to signal than silently drop locks.
        return jsonResponse({ ok: false, error: "human_lock_carryforward_failed", detail: carryErr.message }, 500);
      }

      humanLockCarryforwardCount = (insertedRows || []).length;
      structuredLog("INFO", "reseed_human_lock_carryforward_applied", requestId, interaction_id, newGeneration, {
        human_lock_count: humanLockedSpanInfos.length,
        human_lock_carryforward_count: humanLockCarryforwardCount,
      });
    }
  }

  // ========================================
  // 11. BUILD RECEIPT + WRITE AUDIT LOG
  // ========================================
  const receipt: ReseedReceipt = {
    ok: true,
    interaction_id,
    idempotency_key,
    mode,
    span_count_before: spanCountBefore,
    span_count_after: newSpanIds.length,
    attrib_count_before: attribCountBefore,
    attrib_count_after: humanLockCarryforwardCount, // New spans start with carry-forwarded human locks (if any)
    status: "success",
    human_locked_spans: humanLockedSpans.length > 0 ? humanLockedSpans : undefined,
    human_lock_count: humanLockedSpans.length > 0 ? humanLockedSpans.length : 0,
    human_lock_carryforward_count: humanLockCarryforwardCount,
    superseded_span_ids: activeSpanIds,
    new_span_ids: newSpanIds,
    reroute_triggered: false,
    insert_conflict_recovered: insertConflictRecoveredOverall,
    conflict_constraint: conflictConstraintOverall,
    adopted_generation: adoptedGenerationOverall,
  };

  // ========================================
  // 12. OPTIONAL: TRIGGER REROUTE
  // ========================================
  if (rerouteMode && newSpanIds.length > 0) {
    receipt.reroute_triggered = true;

    // Call context-assembly -> ai-router for each new span, then close-loop integrity checks.
    const contextAssemblyUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/context-assembly`;
    const aiRouterUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-router`;
    const strikingDetectUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/striking-detect`;
    const journalExtractUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/journal-extract`;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET");

    // Headers for internal function-to-function calls
    const internalHeaders: Record<string, string> = {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${serviceKey}`,
    };
    // Add X-Edge-Secret if available for additional auth path
    if (edgeSecret) {
      internalHeaders["X-Edge-Secret"] = edgeSecret;
      internalHeaders["X-Source"] = "admin-reseed";
    }

    const internalEndpoints: InternalEndpoints = {
      contextAssemblyUrl,
      aiRouterUrl,
      strikingDetectUrl,
      journalExtractUrl,
    };

    const rerouteStats = await rerouteSpansWithConcurrency({
      spanIds: newSpanIds,
      interactionId: interaction_id,
      internalHeaders,
      internalEndpoints,
      concurrency: REROUTE_CONCURRENCY,
    });

    receipt.reroute_attempted = rerouteStats.attempted;
    receipt.reroute_succeeded = rerouteStats.succeeded;
    receipt.reroute_failed = rerouteStats.failed;

    if (mode === "reseed_and_close_loop") {
      const closeLoop = await closeLoopAfterReseed({
        db,
        interactionId: interaction_id,
        internalHeaders,
        internalEndpoints,
      });

      receipt.close_loop_applied = true;
      receipt.close_loop_attempts = closeLoop.attempts;
      receipt.close_loop_missing_before = closeLoop.missingBefore;
      receipt.close_loop_missing_after = closeLoop.missingAfter;
      receipt.close_loop_fallback_inserted = closeLoop.fallbackInserted;
      receipt.close_loop_stale_pending_dismissed = closeLoop.stalePendingDismissed;
      receipt.close_loop_pending_on_superseded_after = closeLoop.pendingOnSuperseded;
      receipt.close_loop_pending_null_after = closeLoop.pendingNullSpan;
      receipt.attrib_count_after = closeLoop.latestAttributions;

      if (!closeLoop.ok) {
        receipt.ok = false;
        receipt.status = "error";
        await writeOverrideLog(db, {
          interaction_id,
          idempotency_key,
          reason,
          mode,
          requested_by,
          receipt,
        });
        return jsonResponse({
          ok: false,
          error: "close_loop_integrity_failed",
          detail: closeLoop.detail,
          receipt: { ...receipt, ms: Date.now() - t0 },
        }, 500);
      }
    } else {
      const attributedAfter = await fetchAttributedSpanSet(db, newSpanIds);
      receipt.close_loop_applied = false;
      receipt.close_loop_attempts = 0;
      receipt.close_loop_missing_before = Math.max(0, newSpanIds.length - rerouteStats.succeeded);
      receipt.close_loop_missing_after = Math.max(0, newSpanIds.length - attributedAfter.size);
      receipt.close_loop_fallback_inserted = 0;
      receipt.close_loop_stale_pending_dismissed = 0;
      receipt.close_loop_pending_on_superseded_after = 0;
      receipt.close_loop_pending_null_after = 0;
      receipt.attrib_count_after = attributedAfter.size;
    }
  } else {
    receipt.attrib_count_after = 0;
  }

  // RUNTIME LINEAGE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:admin-reseed", to: "table:public.override_log", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.interactions", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.conversation_spans", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.span_attributions", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.transcripts_comparison", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.calls_raw", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.conversation_spans", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.span_attributions", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.override_log", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.review_queue", type: "writes" },
      { from: "edge:admin-reseed", to: "edge:segment-llm", type: "calls" },
    ];
    if (rerouteMode) {
      lineageEdges.push(
        { from: "edge:admin-reseed", to: "edge:context-assembly", type: "calls" },
        { from: "edge:admin-reseed", to: "edge:ai-router", type: "calls" },
        { from: "edge:admin-reseed", to: "edge:striking-detect", type: "calls" },
        { from: "edge:admin-reseed", to: "edge:journal-extract", type: "calls" },
      );
    }
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: interaction_id,
      source_run_id: "admin-reseed:" + VERSION,
      transcript_variant: "baseline",
      metadata: {
        edges: lineageEdges,
        pipeline_version: VERSION,
        mode,
      },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage must never block */ }

  // ========================================
  // 13. RESPONSE
  // ========================================
  await writeOverrideLog(db, {
    interaction_id,
    idempotency_key,
    reason,
    mode,
    requested_by,
    receipt,
  });

  // Structured log: reseed_end
  structuredLog("INFO", "reseed_end", requestId, interaction_id, newGeneration, {
    outcome: "success",
    duration_ms: Date.now() - t0,
    spans_total: newSpanIds.length,
    spans_active: newSpanIds.length,
    reroute_triggered: receipt.reroute_triggered,
  });

  console.log(
    `[admin-reseed] Rechunk completed: interaction=${interaction_id}, spans_before=${spanCountBefore}, spans_after=${newSpanIds.length}, ` +
      `mode=${mode}, reroute=${receipt.reroute_triggered}`,
  );

  // RUNTIME LINEAGE EVIDENCE (fire-and-forget)
  try {
    const lineageEdges: { from: string; to: string; type: string }[] = [
      { from: "edge:admin-reseed", to: "table:public.conversation_spans", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.span_attributions", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.override_log", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.interactions", type: "reads" },
      { from: "edge:admin-reseed", to: "table:public.conversation_spans", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.span_attributions", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.override_log", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.striking_signals", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.journal_claims", type: "writes" },
      { from: "edge:admin-reseed", to: "table:public.review_queue", type: "writes" },
    ];
    if (receipt.reroute_triggered) {
      lineageEdges.push({ from: "edge:admin-reseed", to: "edge:context-assembly", type: "calls" });
      lineageEdges.push({ from: "edge:admin-reseed", to: "edge:ai-router", type: "calls" });
      lineageEdges.push({ from: "edge:admin-reseed", to: "edge:striking-detect", type: "calls" });
      lineageEdges.push({ from: "edge:admin-reseed", to: "edge:journal-extract", type: "calls" });
    }
    const { error: lineageErr } = await db.from("evidence_events").upsert({
      source_type: "lineage",
      source_id: interaction_id,
      source_run_id: "admin-reseed:" + VERSION,
      transcript_variant: "baseline",
      metadata: { edges: lineageEdges, pipeline_version: VERSION },
    }, { onConflict: "source_type,source_id,transcript_variant" });
    if (lineageErr) console.warn(`lineage_emit: ${lineageErr.message}`);
  } catch { /* lineage emission must never block the response */ }

  return jsonResponse({
    ok: true,
    receipt: { ...receipt, ms: Date.now() - t0 },
  }, 200);
});

// ============================================================
// HELPERS
// ============================================================

interface InternalEndpoints {
  contextAssemblyUrl: string;
  aiRouterUrl: string;
  strikingDetectUrl: string;
  journalExtractUrl: string;
}

interface CloseLoopResult {
  ok: boolean;
  detail: string;
  attempts: number;
  missingBefore: number;
  missingAfter: number;
  fallbackInserted: number;
  stalePendingDismissed: number;
  pendingOnSuperseded: number;
  pendingNullSpan: number;
  latestAttributions: number;
}

interface RerouteBatchResult {
  attempted: number;
  succeeded: number;
  failed: number;
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const signal = AbortSignal.timeout(timeoutMs);
  return await fetch(url, { ...init, signal });
}

async function rerouteSpansWithConcurrency(params: {
  spanIds: string[];
  interactionId: string;
  internalHeaders: Record<string, string>;
  internalEndpoints: InternalEndpoints;
  concurrency: number;
}): Promise<RerouteBatchResult> {
  const { spanIds, interactionId, internalHeaders, internalEndpoints } = params;
  if (spanIds.length === 0) {
    return { attempted: 0, succeeded: 0, failed: 0 };
  }

  const queue = [...spanIds];
  const workerCount = Math.min(Math.max(1, params.concurrency), queue.length);
  let succeeded = 0;
  let failed = 0;

  async function worker() {
    while (queue.length > 0) {
      const spanId = queue.shift();
      if (!spanId) break;
      const ok = await rerouteSpan({
        spanId,
        interactionId,
        internalHeaders,
        internalEndpoints,
      });
      if (ok) succeeded++;
      else failed++;
    }
  }

  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return { attempted: spanIds.length, succeeded, failed };
}

async function rerouteSpan(params: {
  spanId: string;
  interactionId: string;
  internalHeaders: Record<string, string>;
  internalEndpoints: InternalEndpoints;
}): Promise<boolean> {
  const { spanId, interactionId, internalHeaders, internalEndpoints } = params;

  try {
    const ctxResp = await fetchWithTimeout(
      internalEndpoints.contextAssemblyUrl,
      {
        method: "POST",
        headers: internalHeaders,
        body: JSON.stringify({ span_id: spanId }),
      },
      INTERNAL_CALL_TIMEOUT_MS,
    );

    if (!ctxResp.ok) {
      const errText = await ctxResp.text().catch(() => "");
      console.error(`[admin-reseed] context-assembly failed for span ${spanId}: ${ctxResp.status} ${errText}`);
      return false;
    }

    const ctxData = await ctxResp.json();
    if (!ctxData.ok || !ctxData.context_package) {
      console.error(`[admin-reseed] context-assembly returned no package for span ${spanId}`);
      return false;
    }

    const routerResp = await fetchWithTimeout(
      internalEndpoints.aiRouterUrl,
      {
        method: "POST",
        headers: internalHeaders,
        body: JSON.stringify({
          context_package: ctxData.context_package,
          dry_run: false,
        }),
      },
      INTERNAL_CALL_TIMEOUT_MS,
    );

    if (!routerResp.ok) {
      console.error(`[admin-reseed] ai-router failed for span ${spanId}: ${routerResp.status}`);
      return false;
    }

    let routerData: any = null;
    try {
      routerData = await routerResp.json();
    } catch {
      // Non-fatal: still consider reroute successful if HTTP succeeded.
    }

    fetchWithTimeout(internalEndpoints.strikingDetectUrl, {
      method: "POST",
      headers: internalHeaders,
      body: JSON.stringify({
        span_id: spanId,
        interaction_id: interactionId,
        source: "admin-reseed",
      }),
    }, Math.floor(INTERNAL_CALL_TIMEOUT_MS / 2)).catch((e: unknown) => {
      const msg = e instanceof Error ? e.message : "Unknown error";
      console.error(`[admin-reseed] striking-detect post-hook failed for span ${spanId}: ${msg}`);
    });

    const appliedProjectId = routerData?.gatekeeper?.applied_project_id;
    const routerDecision = routerData?.decision;
    if (routerDecision === "assign" && appliedProjectId) {
      fetchWithTimeout(internalEndpoints.journalExtractUrl, {
        method: "POST",
        headers: internalHeaders,
        body: JSON.stringify({
          span_id: spanId,
          interaction_id: interactionId,
          project_id: appliedProjectId,
          source: "admin-reseed",
        }),
      }, Math.floor(INTERNAL_CALL_TIMEOUT_MS / 2)).catch((e: unknown) => {
        const msg = e instanceof Error ? e.message : "Unknown error";
        console.error(`[admin-reseed] journal-extract post-hook failed for span ${spanId}: ${msg}`);
      });
    }

    console.log(`[admin-reseed] Rerouted span ${spanId}`);
    return true;
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : "Unknown error";
    console.error(`[admin-reseed] Reroute error for span ${spanId}: ${msg}`);
    return false;
  }
}

async function fetchLatestActiveSpans(
  db: any,
  interactionId: string,
): Promise<Array<{ id: string; span_index: number; segment_generation: number }>> {
  const { data, error } = await db
    .from("conversation_spans")
    .select("id, span_index, segment_generation")
    .eq("interaction_id", interactionId)
    .eq("is_superseded", false)
    .order("span_index");

  if (error) {
    throw new Error(`latest_spans_fetch_failed:${error.message}`);
  }

  const spans = data || [];
  if (spans.length === 0) return [];
  const maxGeneration = Math.max(...spans.map((s: any) => Number(s.segment_generation || 0)));
  return spans.filter((s: any) => Number(s.segment_generation || 0) === maxGeneration);
}

async function fetchAttributedSpanSet(
  db: any,
  spanIds: string[],
): Promise<Set<string>> {
  if (spanIds.length === 0) return new Set();
  const { data, error } = await db
    .from("span_attributions")
    .select("span_id")
    .in("span_id", spanIds);
  if (error) {
    throw new Error(`attribution_fetch_failed:${error.message}`);
  }
  return new Set((data || []).map((row: any) => row.span_id));
}

function isActiveSpanUniqueConflict(
  error: { message?: string | null; details?: string | null; code?: string | null } | null | undefined,
): boolean {
  if (!error) return false;
  const blob = `${error.message || ""} ${error.details || ""}`.toLowerCase();
  return blob.includes("conversation_spans_active_unique") ||
    (blob.includes("duplicate key value violates unique constraint") &&
      blob.includes("conversation_spans"));
}

async function insertCloseLoopFallbackAttributions(
  db: any,
  interactionId: string,
  spanIds: string[],
): Promise<number> {
  if (spanIds.length === 0) return 0;
  const now = new Date().toISOString();
  const rows = spanIds.map((spanId) => ({
    span_id: spanId,
    decision: "review",
    confidence: 0,
    reasoning: "admin-reseed close-loop fallback: missing attribution after reroute retries",
    anchors: [],
    suggested_aliases: [],
    journal_references: [],
    needs_review: true,
    attribution_source: "system_close_loop_fallback",
    evidence_tier: 3,
    model_id: CLOSE_LOOP_MODEL_ID,
    prompt_version: CLOSE_LOOP_PROMPT_VERSION,
    attributed_by: `admin-reseed-${VERSION}`,
    attributed_at: now,
    raw_response: {
      source: "admin-reseed-close-loop",
      interaction_id: interactionId,
      fallback_reason: "missing_attribution_after_reroute",
    },
  }));

  const { data, error } = await db
    .from("span_attributions")
    .upsert(rows, {
      onConflict: "span_id,model_id,prompt_version",
      ignoreDuplicates: false,
    })
    .select("span_id");

  if (error) {
    throw new Error(`fallback_attribution_upsert_failed:${error.message}`);
  }
  return (data || []).length;
}

async function upsertCloseLoopReviewRows(
  db: any,
  interactionId: string,
  spanIds: string[],
): Promise<void> {
  if (spanIds.length === 0) return;
  const now = new Date().toISOString();
  const rows = spanIds.map((spanId) => ({
    interaction_id: interactionId,
    span_id: spanId,
    status: "pending",
    reason_codes: ["close_loop_missing_attribution"],
    reasons: ["close_loop_missing_attribution"],
    context_payload: {
      source: "admin-reseed-close-loop",
      span_id: spanId,
      created_at_utc: now,
    },
  }));

  const { error } = await db
    .from("review_queue")
    .upsert(rows, { onConflict: "span_id" });

  if (error) {
    throw new Error(`close_loop_review_queue_upsert_failed:${error.message}`);
  }
}

async function dismissStalePendingRows(
  db: any,
  interactionId: string,
): Promise<number> {
  const { data: staleRows, error: staleErr } = await db
    .from("review_queue")
    .select("id, span_id")
    .eq("interaction_id", interactionId)
    .eq("status", "pending");

  if (staleErr) {
    throw new Error(`stale_rows_query_failed:${staleErr.message}`);
  }

  const pendingRows = staleRows || [];
  if (pendingRows.length === 0) return 0;

  const spanIds = pendingRows.map((row: any) => row.span_id).filter(Boolean);
  let spanScope = new Map<string, { interaction_id: string; is_superseded: boolean }>();
  if (spanIds.length > 0) {
    const { data: spans, error: spansErr } = await db
      .from("conversation_spans")
      .select("id, interaction_id, is_superseded")
      .in("id", spanIds);
    if (spansErr) {
      throw new Error(`stale_rows_span_scope_failed:${spansErr.message}`);
    }
    spanScope = new Map((spans || []).map((s: any) => [s.id, {
      interaction_id: s.interaction_id,
      is_superseded: Boolean(s.is_superseded),
    }]));
  }

  const staleIds = pendingRows
    .filter((row: any) => {
      if (!row.span_id) return true;
      const scope = spanScope.get(row.span_id);
      if (!scope) return true;
      if (scope.interaction_id !== interactionId) return true;
      return scope.is_superseded === true;
    })
    .map((row: any) => row.id);

  if (staleIds.length === 0) return 0;

  const { error: updErr } = await db
    .from("review_queue")
    .update({
      status: "dismissed",
      resolved_at: new Date().toISOString(),
      resolved_by: "admin-reseed",
      resolution_action: "auto_dismiss",
      resolution_notes: "[admin-reseed close-loop] stale pending row auto-dismissed",
    })
    .in("id", staleIds);

  if (updErr) {
    throw new Error(`stale_rows_dismiss_failed:${updErr.message}`);
  }
  return staleIds.length;
}

async function getPendingScopeCounts(
  db: any,
  interactionId: string,
): Promise<{ pendingOnSuperseded: number; pendingNullSpan: number; pendingOnActive: number }> {
  const { data, error } = await db
    .from("review_queue")
    .select("id, span_id, status")
    .eq("interaction_id", interactionId)
    .eq("status", "pending");

  if (error) {
    throw new Error(`pending_counts_query_failed:${error.message}`);
  }

  const rows = data || [];
  const spanIds = rows.map((row: any) => row.span_id).filter(Boolean);
  const scope = new Map<string, { is_superseded: boolean }>();
  if (spanIds.length > 0) {
    const { data: spans, error: spansErr } = await db
      .from("conversation_spans")
      .select("id, is_superseded")
      .in("id", spanIds);
    if (spansErr) {
      throw new Error(`pending_counts_span_scope_failed:${spansErr.message}`);
    }
    for (const span of spans || []) {
      scope.set((span as any).id, { is_superseded: Boolean((span as any).is_superseded) });
    }
  }

  let pendingOnSuperseded = 0;
  let pendingNullSpan = 0;
  let pendingOnActive = 0;
  for (const row of rows) {
    const spanId = (row as any).span_id;
    if (!spanId) {
      pendingNullSpan++;
      continue;
    }
    const state = scope.get(spanId);
    if (!state) {
      pendingNullSpan++;
      continue;
    }
    if (state.is_superseded) pendingOnSuperseded++;
    else pendingOnActive++;
  }

  return { pendingOnSuperseded, pendingNullSpan, pendingOnActive };
}

async function closeLoopAfterReseed(params: {
  db: any;
  interactionId: string;
  internalHeaders: Record<string, string>;
  internalEndpoints: InternalEndpoints;
}): Promise<CloseLoopResult> {
  const { db, interactionId, internalHeaders, internalEndpoints } = params;

  let attempts = 0;
  let missingBefore = 0;
  let missingAfter = 0;
  let fallbackInserted = 0;

  try {
    for (let attempt = 1; attempt <= CLOSE_LOOP_MAX_ATTEMPTS; attempt++) {
      attempts = attempt;
      const latestSpans = await fetchLatestActiveSpans(db, interactionId);
      const latestIds = latestSpans.map((s) => s.id);
      const attributed = await fetchAttributedSpanSet(db, latestIds);
      const missing = latestIds.filter((id) => !attributed.has(id));
      if (attempt === 1) missingBefore = missing.length;
      if (missing.length === 0) break;

      await rerouteSpansWithConcurrency({
        spanIds: missing,
        interactionId,
        internalHeaders,
        internalEndpoints,
        concurrency: REROUTE_CONCURRENCY,
      });
    }

    const latestSpansAfter = await fetchLatestActiveSpans(db, interactionId);
    const latestIdsAfter = latestSpansAfter.map((s) => s.id);
    const attributedAfter = await fetchAttributedSpanSet(db, latestIdsAfter);
    let missingFinal = latestIdsAfter.filter((id) => !attributedAfter.has(id));

    if (missingFinal.length > 0) {
      fallbackInserted = await insertCloseLoopFallbackAttributions(db, interactionId, missingFinal);
      await upsertCloseLoopReviewRows(db, interactionId, missingFinal);

      const attributedAfterFallback = await fetchAttributedSpanSet(db, latestIdsAfter);
      missingFinal = latestIdsAfter.filter((id) => !attributedAfterFallback.has(id));
    }
    missingAfter = missingFinal.length;

    const stalePendingDismissed = await dismissStalePendingRows(db, interactionId);
    const pendingCounts = await getPendingScopeCounts(db, interactionId);
    const ok = missingAfter === 0 && pendingCounts.pendingOnSuperseded === 0 && pendingCounts.pendingNullSpan === 0;

    return {
      ok,
      detail: ok
        ? "close_loop_ok"
        : `integrity_violation missing_after=${missingAfter} pending_on_superseded=${pendingCounts.pendingOnSuperseded} pending_null=${pendingCounts.pendingNullSpan}`,
      attempts,
      missingBefore,
      missingAfter,
      fallbackInserted,
      stalePendingDismissed,
      pendingOnSuperseded: pendingCounts.pendingOnSuperseded,
      pendingNullSpan: pendingCounts.pendingNullSpan,
      latestAttributions: latestIdsAfter.length - missingAfter,
    };
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : "unknown";
    return {
      ok: false,
      detail: `close_loop_error:${msg}`,
      attempts,
      missingBefore,
      missingAfter: Number.MAX_SAFE_INTEGER,
      fallbackInserted,
      stalePendingDismissed: 0,
      pendingOnSuperseded: Number.MAX_SAFE_INTEGER,
      pendingNullSpan: Number.MAX_SAFE_INTEGER,
      latestAttributions: 0,
    };
  }
}

function jsonResponse(data: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Deterministic fallback split for long transcripts when LLM fails to segment.
 * Strategy: Split by paragraph breaks, or by fixed character chunks if no paragraphs.
 */
function deterministicSplit(transcript: string, transcriptChars: number): SegmentFromLLM[] {
  const MIN_CHUNK_SIZE = 500;
  const TARGET_CHUNKS = Math.min(4, Math.ceil(transcriptChars / 2000));

  // Try paragraph-based split first (double newlines)
  const paragraphs = transcript.split(/\n\n+/);

  if (paragraphs.length >= 2) {
    // Merge small paragraphs into chunks
    const chunks: { text: string; start: number; end: number }[] = [];
    let cursor = 0;
    let currentChunk = { text: "", start: 0, end: 0 };

    for (const para of paragraphs) {
      const paraStart = transcript.indexOf(para, cursor);
      const paraEnd = paraStart + para.length;

      if (currentChunk.text.length === 0) {
        currentChunk = { text: para, start: paraStart, end: paraEnd };
      } else if (currentChunk.text.length + para.length < MIN_CHUNK_SIZE) {
        currentChunk.text += "\n\n" + para;
        currentChunk.end = paraEnd;
      } else {
        chunks.push(currentChunk);
        currentChunk = { text: para, start: paraStart, end: paraEnd };
      }
      cursor = paraEnd;
    }
    if (currentChunk.text.length > 0) {
      chunks.push(currentChunk);
    }

    if (chunks.length >= 2) {
      return chunks.map((c, i) => ({
        span_index: i,
        char_start: c.start,
        char_end: c.end,
        boundary_reason: "fallback_paragraph_split",
        confidence: 0.5,
        boundary_quote: null,
      }));
    }
  }

  // Fixed character split fallback
  const chunkSize = Math.ceil(transcriptChars / TARGET_CHUNKS);
  const segments: SegmentFromLLM[] = [];

  for (let i = 0; i < TARGET_CHUNKS; i++) {
    const start = i * chunkSize;
    const end = Math.min((i + 1) * chunkSize, transcriptChars);
    if (start >= transcriptChars) break;

    segments.push({
      span_index: i,
      char_start: start,
      char_end: end,
      boundary_reason: "fallback_fixed_split",
      confidence: 0.3,
      boundary_quote: null,
    });
  }

  // Ensure last segment ends at transcript end
  if (segments.length > 0) {
    segments[segments.length - 1].char_end = transcriptChars;
  }

  return segments.length > 0 ? segments : [{
    span_index: 0,
    char_start: 0,
    char_end: transcriptChars,
    boundary_reason: "fallback_full_call",
    confidence: 1.0,
    boundary_quote: null,
  }];
}

async function writeOverrideLog(
  db: any,
  params: {
    interaction_id: string;
    idempotency_key: string;
    reason: string;
    mode: string;
    requested_by: string;
    receipt: ReseedReceipt;
  },
): Promise<void> {
  const { error } = await db
    .from("override_log")
    .insert({
      entity_type: "reseed",
      entity_key: `interaction:${params.interaction_id}`,
      field_name: "conversation_spans",
      from_value: `generation:${params.receipt.span_count_before}`,
      to_value: `generation:${params.receipt.span_count_after}`,
      reason: params.reason,
      idempotency_key: params.idempotency_key,
      mode: params.mode,
      requested_by: params.requested_by,
      interaction_id: params.interaction_id,
      span_count_before: params.receipt.span_count_before,
      span_count_after: params.receipt.span_count_after,
      attrib_count_before: params.receipt.attrib_count_before,
      attrib_count_after: params.receipt.attrib_count_after,
      reseed_status: params.receipt.status,
      effects_receipt: params.receipt,
    });

  if (error) {
    console.error("[admin-reseed] Failed to write override_log:", error.message);
    // Don't fail the whole operation for audit log failure
    // But log it clearly
  }
}
